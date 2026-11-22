// Package api serves a box's machine state to the browser panel: memory, CPU
// and traffic of its cgroup, the supervised services with restart and on/off
// controls, and the listening ports. It runs inside the box and is reached
// only through the box's private front door.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"
)

// Options name the commands and paths the API works with; tests substitute fakes.
type Options struct {
	// Service is the supervisor's command prefix, `denbox service` in a box;
	// the API appends `status`, `start NAME`, `stop NAME` or `restart NAME`.
	Service []string
	// SS is iproute2's ss.
	SS string
	// ProcRoot holds proc/ and sys/fs/cgroup/; "/" in a box.
	ProcRoot string
	// Interface is the network interface whose traffic the panel shows.
	Interface string
	// OptionalServices stay off until switched on; a marker file in
	// OptionalServicesDir records each one that is on.
	OptionalServices    []string
	OptionalServicesDir string
	// SelfService is this API's own service, restarted last.
	SelfService string
	// Bundle is the browser bundle served at /bundle.json; empty when the box
	// has no browser parts.
	Bundle string
}

// Web pages cannot send this header cross-origin without a CORS preflight,
// which this server never answers, so only the extension can call it.
const guardHeader = "x-denbox-api"

type App struct {
	Options
	mu       sync.Mutex
	previous *sample
}

func New(options Options) *App {
	if options.ProcRoot == "" {
		options.ProcRoot = "/"
	}
	if options.Interface == "" {
		options.Interface = "eth0"
	}
	if options.SelfService == "" {
		options.SelfService = "denbox-api"
	}
	return &App{Options: options}
}

// Part is one section of the state: its value, or why it could not be read.
// It encodes as the value, or as {"state":"unavailable","reason":...}.
type Part[T any] struct {
	Value T
	Err   error
}

func (p Part[T]) MarshalJSON() ([]byte, error) {
	if p.Err != nil {
		return json.Marshal(struct {
			State  string `json:"state"`
			Reason string `json:"reason"`
		}{"unavailable", firstLine(p.Err)})
	}
	return json.Marshal(p.Value)
}

func part[T any](value T, err error) Part[T] { return Part[T]{value, err} }

type State struct {
	System   Part[System]    `json:"system"`
	Services Part[[]Service] `json:"services"`
	Ports    Part[[]Port]    `json:"ports"`
}

// state reads the three sections in parallel; one failing leaves the others.
func (a *App) state() State {
	var state State
	var wait sync.WaitGroup
	wait.Add(3)
	go func() { defer wait.Done(); state.System = part(a.system()) }()
	go func() { defer wait.Done(); state.Services = part(a.services()) }()
	go func() { defer wait.Done(); state.Ports = part(a.ports()) }()
	wait.Wait()
	return state
}

// statusError is an error the client caused, answered with its status code.
type statusError struct {
	code int
	error
}

func badRequest(message string) error { return statusError{http.StatusBadRequest, errors.New(message)} }

// firstLine is an error message fit for the panel: first line, 300 characters.
func firstLine(err error) string {
	text := strings.TrimSpace(err.Error())
	if exit := new(exec.ExitError); errors.As(err, &exit) && len(exit.Stderr) > 0 {
		text = strings.TrimSpace(string(exit.Stderr))
	}
	text, _, _ = strings.Cut(text, "\n")
	if runes := []rune(text); len(runes) > 300 {
		text = string(runes[:300])
	}
	return text
}

type handler func(body []byte) (any, error)

// decode reads a POST body into T; an empty body is T's zero value.
func decode[T any](body []byte) (T, error) {
	var value T
	if len(body) > 0 && json.Unmarshal(body, &value) != nil {
		return value, badRequest("invalid JSON")
	}
	return value, nil
}

func (a *App) routes() map[string]handler {
	return map[string]handler{
		"GET /state": func([]byte) (any, error) { return a.state(), nil },
		"GET /bundle.json": func([]byte) (any, error) {
			if a.Bundle == "" {
				return nil, statusError{http.StatusNotFound, errors.New("this box has no browser parts")}
			}
			raw, err := os.ReadFile(a.Bundle)
			return json.RawMessage(raw), err
		},
		"POST /services/restart": func(body []byte) (any, error) {
			request, err := decode[struct {
				Name string `json:"name"`
			}](body)
			if err != nil {
				return nil, err
			}
			return a.restart(request.Name)
		},
		"POST /services/toggle": func(body []byte) (any, error) {
			request, err := decode[struct {
				Name string `json:"name"`
				On   *bool  `json:"on"`
			}](body)
			if err != nil {
				return nil, err
			}
			if request.On == nil {
				return nil, badRequest("on must be true or false")
			}
			return a.toggle(request.Name, *request.On)
		},
	}
}

func (a *App) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	reply := func(code int, body any) {
		writer.Header().Set("content-type", "application/json")
		writer.Header().Set("cache-control", "no-store")
		writer.WriteHeader(code)
		_ = json.NewEncoder(writer).Encode(body)
	}
	type failure struct {
		Error string `json:"error"`
	}
	if request.Header.Get(guardHeader) != "1" {
		reply(http.StatusForbidden, failure{"missing " + guardHeader + " header"})
		return
	}
	route, ok := a.routes()[request.Method+" "+request.URL.Path]
	if !ok {
		reply(http.StatusNotFound, failure{"not found"})
		return
	}
	const limit = 4096
	body, err := io.ReadAll(io.LimitReader(request.Body, limit+1))
	if err != nil || len(body) > limit {
		reply(http.StatusBadRequest, failure{"request body too large"})
		return
	}
	value, err := route(body)
	if err != nil {
		code := http.StatusInternalServerError
		if status := new(statusError); errors.As(err, status) {
			code = status.code
		}
		reply(code, failure{firstLine(err)})
		return
	}
	reply(http.StatusOK, value)
}

// run executes a command that answers within the timeout.
func run(timeout time.Duration, command string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, command, args...).Output()
	return string(out), err
}

// service runs the supervisor command with args, such as `stop NAME`.
func (a *App) service(timeout time.Duration, args ...string) (string, error) {
	return run(timeout, a.Service[0], slices.Concat(a.Service[1:], args)...)
}
