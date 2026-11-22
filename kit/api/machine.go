package api

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type System struct {
	UptimeSeconds int64   `json:"uptimeSeconds"`
	Memory        Memory  `json:"memory"`
	CPU           CPU     `json:"cpu"`
	Network       Network `json:"network"`
}

// Memory is the cgroup's; LimitBytes is null without a limit.
type Memory struct {
	UsedBytes  int64  `json:"usedBytes"`
	LimitBytes *int64 `json:"limitBytes"`
	AnonBytes  int64  `json:"anonBytes"`
	FileBytes  int64  `json:"fileBytes"`
}

// CPU.Percent is null on the first read: it is a delta since the previous one.
type CPU struct {
	Percent    *float64 `json:"percent"`
	LimitCores *float64 `json:"limitCores"`
}

// Network counts Options.Interface since it came up; rates are null on the first read.
type Network struct {
	RxBytes          int64    `json:"rxBytes"`
	TxBytes          int64    `json:"txBytes"`
	RxBytesPerSecond *float64 `json:"rxBytesPerSecond"`
	TxBytesPerSecond *float64 `json:"txBytesPerSecond"`
}

type sample struct {
	at                time.Time
	cpuMicros, rx, tx int64
}

func (a *App) read(path string) (string, error) {
	raw, err := os.ReadFile(filepath.Join(a.ProcRoot, path))
	return string(raw), err
}

// field reads "key value" lines such as memory.stat and cpu.stat.
func field(text, key string) int64 {
	for _, line := range strings.Split(text, "\n") {
		if name, value, ok := strings.Cut(line, " "); ok && name == key {
			number, _ := strconv.ParseInt(value, 10, 64)
			return number
		}
	}
	return 0
}

// afterComm splits /proc/PID/stat after the command name, which may hold spaces.
func afterComm(stat string) []string {
	index := strings.LastIndex(stat, ")")
	if index < 0 || index+2 > len(stat) {
		return nil
	}
	return strings.Fields(stat[index+2:])
}

var spaces = regexp.MustCompile(`\s+`)

// system reads cgroup v2 and /proc.
func (a *App) system() (System, error) {
	files := map[string]string{}
	for _, path := range []string{"sys/fs/cgroup/memory.current", "sys/fs/cgroup/memory.max", "sys/fs/cgroup/memory.stat",
		"sys/fs/cgroup/cpu.stat", "sys/fs/cgroup/cpu.max", "proc/net/dev", "proc/uptime", "proc/1/stat"} {
		text, err := a.read(path)
		if err != nil {
			return System{}, err
		}
		files[path] = text
	}

	var rx, tx int64
	for _, line := range strings.Split(files["proc/net/dev"], "\n") {
		name, counters, found := strings.Cut(strings.TrimSpace(line), ":")
		if values := strings.Fields(counters); found && name == a.Interface && len(values) > 8 {
			rx, _ = strconv.ParseInt(values[0], 10, 64)
			tx, _ = strconv.ParseInt(values[8], 10, 64)
		}
	}

	var system System
	memory := &system.Memory
	memory.UsedBytes, _ = strconv.ParseInt(strings.TrimSpace(files["sys/fs/cgroup/memory.current"]), 10, 64)
	if limit, err := strconv.ParseInt(strings.TrimSpace(files["sys/fs/cgroup/memory.max"]), 10, 64); err == nil {
		memory.LimitBytes = &limit
	}
	memory.AnonBytes = field(files["sys/fs/cgroup/memory.stat"], "anon")
	memory.FileBytes = field(files["sys/fs/cgroup/memory.stat"], "file")

	if quota := spaces.Split(strings.TrimSpace(files["sys/fs/cgroup/cpu.max"]), -1); len(quota) == 2 && quota[0] != "max" {
		q, _ := strconv.ParseFloat(quota[0], 64)
		p, _ := strconv.ParseFloat(quota[1], 64)
		if p > 0 {
			cores := q / p
			system.CPU.LimitCores = &cores
		}
	}

	// Field 22 of /proc/1/stat is the box's start in clock ticks after boot.
	if fields := afterComm(files["proc/1/stat"]); len(fields) > 19 {
		start, _ := strconv.ParseFloat(fields[19], 64)
		host, _ := strconv.ParseFloat(strings.Fields(files["proc/uptime"])[0], 64)
		system.UptimeSeconds = int64(max(0, host-start/100) + 0.5)
	}

	cpuMicros := field(files["sys/fs/cgroup/cpu.stat"], "usage_usec")
	now := time.Now()
	a.mu.Lock()
	previous := a.previous
	a.previous = &sample{at: now, cpuMicros: cpuMicros, rx: rx, tx: tx}
	a.mu.Unlock()

	system.Network = Network{RxBytes: rx, TxBytes: tx}
	if previous != nil {
		if seconds := now.Sub(previous.at).Seconds(); seconds > 0 {
			rate := func(delta int64) *float64 { value := float64(max(0, delta)) / seconds; return &value }
			percent := *rate(cpuMicros - previous.cpuMicros) / 1e4
			system.CPU.Percent = &percent
			system.Network.RxBytesPerSecond = rate(rx - previous.rx)
			system.Network.TxBytesPerSecond = rate(tx - previous.tx)
		}
	}
	return system, nil
}
