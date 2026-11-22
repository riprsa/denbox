package api

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Service struct {
	Name     string `json:"name"`
	Up       bool   `json:"up"`
	Seconds  int    `json:"seconds"`
	Optional bool   `json:"optional"`
	// Enabled is false only for an optional service that is switched off.
	Enabled bool `json:"enabled"`
}

// Process is the supervised service owning the port, or the process name ss
// reported; null for a process in another PID namespace, such as a gateway
// container sharing the network.
type Port struct {
	Address string  `json:"address"`
	Port    int     `json:"port"`
	Process *string `json:"process"`
}

var serviceLine = regexp.MustCompile(`^([a-z][a-z0-9-]*): (up|down)\b.*?(\d+) seconds`)

// enabled reports whether a service may run: an optional one only while its marker exists.
func (a *App) enabled(name string) bool {
	if !slices.Contains(a.OptionalServices, name) {
		return true
	}
	_, err := os.Stat(filepath.Join(a.OptionalServicesDir, name))
	return err == nil
}

func (a *App) services() ([]Service, error) {
	out, err := run(15*time.Second, a.Service, "status")
	if err != nil {
		return nil, err
	}
	list := []Service{}
	for _, line := range strings.Split(out, "\n") {
		match := serviceLine.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		seconds, _ := strconv.Atoi(match[3])
		list = append(list, Service{Name: match[1], Up: match[2] == "up", Seconds: seconds,
			Optional: slices.Contains(a.OptionalServices, match[1]), Enabled: a.enabled(match[1])})
	}
	return list, nil
}

// toggle switches an optional service and remembers the choice in its marker,
// which the service's run script checks, so it lasts across restarts.
func (a *App) toggle(name string, on bool) (Service, error) {
	if !slices.Contains(a.OptionalServices, name) {
		return Service{}, badRequest{errors.New("not an optional service")}
	}
	marker := filepath.Join(a.OptionalServicesDir, name)
	if on {
		if err := os.MkdirAll(a.OptionalServicesDir, 0o700); err != nil {
			return Service{}, err
		}
		if err := os.WriteFile(marker, nil, 0o600); err != nil {
			return Service{}, err
		}
		if _, err := run(15*time.Second, a.Service, "start", name); err != nil {
			return Service{}, err
		}
	} else {
		if err := os.Remove(marker); err != nil && !os.IsNotExist(err) {
			return Service{}, err
		}
		if _, err := run(40*time.Second, a.Service, "stop", name); err != nil {
			return Service{}, err
		}
	}
	list, err := a.services()
	if err != nil {
		return Service{}, err
	}
	for _, service := range list {
		if service.Name == name {
			return service, nil
		}
	}
	return Service{}, fmt.Errorf("%s is not supervised", name)
}

// restart runs detached after the reply, this API's own service last: its
// restart kills the request that asked for it. "all" skips switched-off
// optional services.
func (a *App) restart(name string) (map[string][]string, error) {
	list, err := a.services()
	if err != nil {
		return nil, err
	}
	names := []string{}
	self := false
	for _, service := range list {
		switch {
		case name != "all":
			if service.Name == name {
				names = append(names, name)
			}
		case !service.Enabled:
		case service.Name == a.SelfService:
			self = true
		default:
			names = append(names, service.Name)
		}
	}
	if self {
		names = append(names, a.SelfService)
	}
	if len(names) == 0 {
		return nil, badRequest{errors.New("unknown service")}
	}
	script := `sleep 1; command=$1; shift; for name; do "$command" restart "$name"; done`
	child := exec.Command("sh", append([]string{"-c", script, "sh", a.Service}, names...)...)
	child.Stdout, child.Stderr = os.Stderr, os.Stderr
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		return nil, err
	}
	go func() {
		if err := child.Wait(); err != nil {
			log.Printf("restart %v: %v", names, err)
		}
	}()
	return map[string][]string{"restarting": names}, nil
}

var ssUser = regexp.MustCompile(`users:\(\("([^"]+)",pid=(\d+)`)

// owner is the supervised service a process belongs to: the argument of its
// s6-supervise ancestor, else the fallback.
func (a *App) owner(pid int, fallback string) string {
	current := pid
	for depth := 0; current > 1 && depth < 12; depth++ {
		stat, _ := a.read(fmt.Sprintf("proc/%d/stat", current))
		fields := afterComm(stat)
		if len(fields) < 2 {
			return fallback
		}
		parent, _ := strconv.Atoi(fields[1])
		cmdline, _ := a.read(fmt.Sprintf("proc/%d/cmdline", parent))
		command := strings.Split(cmdline, "\x00")
		if strings.HasSuffix(command[0], "s6-supervise") {
			if len(command) > 1 && command[1] != "" {
				return command[1]
			}
			return fallback
		}
		current = parent
	}
	return fallback
}

// ports lists TCP listeners. Docker's embedded DNS (127.0.0.11) is left out.
func (a *App) ports() ([]Port, error) {
	out, err := run(15*time.Second, a.SS, "-lntpH")
	if err != nil {
		return nil, err
	}
	seen := map[string]Port{}
	for _, line := range strings.Split(out, "\n") {
		columns := strings.Fields(line)
		if len(columns) < 4 {
			continue
		}
		split := strings.LastIndex(columns[3], ":")
		if split < 0 {
			continue
		}
		address := strings.Trim(columns[3][:split], "[]")
		if address == "127.0.0.11" {
			continue
		}
		port := Port{Address: address}
		port.Port, _ = strconv.Atoi(columns[3][split+1:])
		if user := ssUser.FindStringSubmatch(line); user != nil {
			pid, _ := strconv.Atoi(user[2])
			process := a.owner(pid, user[1])
			port.Process = &process
		}
		seen[fmt.Sprintf("%s:%d", address, port.Port)] = port
	}
	list := make([]Port, 0, len(seen))
	for _, port := range seen {
		list = append(list, port)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Port != list[j].Port {
			return list[i].Port < list[j].Port
		}
		return list[i].Address < list[j].Address
	})
	return list, nil
}
