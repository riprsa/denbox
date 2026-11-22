package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A box with three services (code-server optional and off), three listeners
// and a cgroup at 0.9 of 3 GiB. Every fake command appends "<name> <args>" to
// root/calls; status reads are left out.
type fixture struct {
	root, optionalDir string
	server            *httptest.Server
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	fake := func(name, body string) string {
		path := filepath.Join(root, "bin", name)
		must(t, os.MkdirAll(filepath.Dir(path), 0o700))
		script := fmt.Sprintf("#!/bin/sh\nset -eu\n[ \"${1:-}\" = status ] || [ \"${1:-}\" = -lntpH ] || echo \"%s $*\" >> %q\n%s\n", name, filepath.Join(root, "calls"), body)
		must(t, os.WriteFile(path, []byte(script), 0o700))
		return path
	}
	files := map[string]string{
		"sys/fs/cgroup/memory.current": "907497472\n",
		"sys/fs/cgroup/memory.max":     "3221225472\n",
		"sys/fs/cgroup/memory.stat":    "anon 693366784\nfile 183300096\nshmem 26058752\n",
		"sys/fs/cgroup/cpu.stat":       "usage_usec 33288691\nuser_usec 20706020\n",
		"sys/fs/cgroup/cpu.max":        "200000 100000\n",
		"proc/net/dev":                 "Inter-|\n face |\n    lo: 1 2 0 0 0 0 0 0 3 4 0 0 0 0 0 0\n  eth0: 4422232 6114 0 0 0 0 0 0 2082727 4933 0 0 0 0 0 0\n",
		"proc/uptime":                  "1000.00 1900.00\n",
		// Field 22 (start time in ticks): 70000, so the box is up 300 s.
		"proc/1/stat": "1 (my init) S 0 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 70000 1 1\n",
		// t3 (pid 180) runs under a shell (170) under s6-supervise (163); 193 has no supervisor.
		"proc/180/stat": "180 (x) S 170 1 1\n", "proc/180/cmdline": "node",
		"proc/170/stat": "170 (x) S 163 1 1\n", "proc/170/cmdline": "sh",
		"proc/163/stat": "163 (x) S 11 1 1\n", "proc/163/cmdline": "s6-supervise\x00t3\x00",
		"proc/193/stat": "193 (x) S 1 1 1\n", "proc/193/cmdline": "node",
	}
	proc := filepath.Join(root, "proc-root")
	for path, text := range files {
		must(t, os.MkdirAll(filepath.Dir(filepath.Join(proc, path)), 0o700))
		must(t, os.WriteFile(filepath.Join(proc, path), []byte(text), 0o600))
	}
	optional := filepath.Join(root, "optional")
	server := httptest.NewServer(New(Options{
		Service: fake("denbox-service", `[ "$1" = status ] && printf '%s\n' 'code-server: up (pid 227) 286 seconds' 'denbox-api: up (pid 193) 286 seconds' 't3: down (exitcode 1) 3 seconds, ready 3 seconds'
true`),
		SS: fake("ss", `printf '%s\n' \
'LISTEN 0 511 127.0.0.1:48099 0.0.0.0:* users:(("MainThread",pid=193,fd=18))' \
'LISTEN 0 4096 *:1080 *:*' \
'LISTEN 0 4096 127.0.0.11:34041 0.0.0.0:*' \
'LISTEN 0 511 0.0.0.0:3773 0.0.0.0:* users:(("node-MainThread",pid=180,fd=20))'`),
		ProcRoot:            proc,
		OptionalServices:    []string{"code-server"},
		OptionalServicesDir: optional,
	}))
	t.Cleanup(server.Close)
	return &fixture{root: root, optionalDir: optional, server: server}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) call(t *testing.T, method, path string, body any, guard bool) (int, string) {
	t.Helper()
	raw, _ := json.Marshal(body)
	if body == nil {
		raw = nil
	}
	request, _ := http.NewRequest(method, f.server.URL+path, bytes.NewReader(raw))
	if guard {
		request.Header.Set("x-denbox-api", "1")
	}
	response, err := http.DefaultClient.Do(request)
	must(t, err)
	defer response.Body.Close()
	var buffer bytes.Buffer
	_, _ = buffer.ReadFrom(response.Body)
	return response.StatusCode, strings.TrimSpace(buffer.String())
}

func (f *fixture) post(t *testing.T, path string, body any) (int, string) {
	t.Helper()
	return f.call(t, http.MethodPost, path, body, true)
}

func (f *fixture) calls() string {
	raw, _ := os.ReadFile(filepath.Join(f.root, "calls"))
	return strings.ReplaceAll(strings.TrimSpace(string(raw)), "\n", "|")
}

func TestRejectsRequestsWithoutGuardHeader(t *testing.T) {
	f := newFixture(t)
	if code, _ := f.call(t, http.MethodGet, "/state", nil, false); code != 403 {
		t.Fatal(code)
	}
}

func TestStateReportsMachineServicesAndPorts(t *testing.T) {
	f := newFixture(t)
	code, body := f.call(t, http.MethodGet, "/state", nil, true)
	want := `{"system":{"uptimeSeconds":300,` +
		`"memory":{"usedBytes":907497472,"limitBytes":3221225472,"anonBytes":693366784,"fileBytes":183300096},` +
		`"cpu":{"percent":null,"limitCores":2},` +
		`"network":{"rxBytes":4422232,"txBytes":2082727,"rxBytesPerSecond":null,"txBytesPerSecond":null}},` +
		`"services":[{"name":"code-server","up":true,"seconds":286,"optional":true,"enabled":false},` +
		`{"name":"denbox-api","up":true,"seconds":286,"optional":false,"enabled":true},` +
		`{"name":"t3","up":false,"seconds":3,"optional":false,"enabled":true}],` +
		`"ports":[{"address":"*","port":1080,"process":null},{"address":"0.0.0.0","port":3773,"process":"t3"},` +
		`{"address":"127.0.0.1","port":48099,"process":"MainThread"}]}`
	if code != 200 || body != want {
		t.Fatalf("%d\n%s", code, body)
	}
	// The second read has rates.
	_, body = f.call(t, http.MethodGet, "/state", nil, true)
	if strings.Contains(body, `"percent":null`) {
		t.Fatal(body)
	}
}

func TestAFailingSectionLeavesTheOthers(t *testing.T) {
	f := newFixture(t)
	must(t, os.Remove(filepath.Join(f.root, "proc-root/sys/fs/cgroup/memory.current")))
	_, body := f.call(t, http.MethodGet, "/state", nil, true)
	if !strings.HasPrefix(body, `{"system":{"state":"unavailable","reason":"open `) || !strings.Contains(body, `"services":[{`) {
		t.Fatal(body)
	}
}

func TestRestartValidatesSkipsOffServicesAndRestartsSelfLast(t *testing.T) {
	f := newFixture(t)
	if code, _ := f.post(t, "/services/restart", map[string]string{"name": "nope; reboot"}); code != 400 {
		t.Fatal(code)
	}
	if _, body := f.post(t, "/services/restart", map[string]string{"name": "all"}); body != `{"restarting":["t3","denbox-api"]}` {
		t.Fatal(body)
	}
	deadline := time.Now().Add(5 * time.Second)
	for f.calls() != "denbox-service restart t3|denbox-service restart denbox-api" {
		if time.Now().After(deadline) {
			t.Fatal(f.calls())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestToggleSwitchesOnlyOptionalServices(t *testing.T) {
	f := newFixture(t)
	for _, body := range []any{map[string]any{"name": "t3", "enabled": false}, map[string]any{"name": "code-server"}, "x"} {
		if code, _ := f.post(t, "/services/toggle", body); code != 400 {
			t.Fatalf("%v: %d", body, code)
		}
	}
	if _, body := f.post(t, "/services/toggle", map[string]any{"name": "code-server", "enabled": true}); !strings.Contains(body, `"enabled":true`) {
		t.Fatal(body)
	}
	if entries, _ := os.ReadDir(f.optionalDir); len(entries) != 1 || entries[0].Name() != "code-server" {
		t.Fatal(entries)
	}
	if _, body := f.post(t, "/services/toggle", map[string]any{"name": "code-server", "enabled": false}); !strings.Contains(body, `"enabled":false`) {
		t.Fatal(body)
	}
	if entries, _ := os.ReadDir(f.optionalDir); len(entries) != 0 {
		t.Fatal(entries)
	}
	if got := f.calls(); got != "denbox-service start code-server|denbox-service stop code-server" {
		t.Fatal(got)
	}
}
