package isolation

import (
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestRuntimeRestrictions(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Fatal("container process unexpectedly runs as root")
	}

	assertWriteFails(t, "/workspace/host-write")
	assertWriteFails(t, "/root-filesystem-write")
	assertWriteFails(t, "/results/result.txt")

	if err := os.WriteFile("/tmp/isolation-scratch", []byte("ok"), 0o600); err != nil {
		t.Fatalf("writable isolated tmpfs is unavailable: %v", err)
	}
	for _, variable := range []string{
		"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
		"http_proxy", "https_proxy", "all_proxy", "no_proxy",
		"FTP_PROXY", "ftp_proxy",
	} {
		if value := os.Getenv(variable); value != "" {
			t.Fatalf("container inherited proxy variable %s=%q", variable, value)
		}
	}

	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatalf("list network interfaces: %v", err)
	}
	for _, networkInterface := range interfaces {
		if networkInterface.Name == "lo" || networkInterface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if networkInterface.Flags&net.FlagUp != 0 {
			t.Fatalf("container has an active non-loopback network interface: %s (%s)", networkInterface.Name, networkInterface.Flags)
		}
		addresses, addressErr := networkInterface.Addrs()
		if addressErr != nil {
			t.Fatalf("list addresses for network interface %s: %v", networkInterface.Name, addressErr)
		}
		if len(addresses) != 0 {
			t.Fatalf("disabled non-loopback network interface %s has addresses: %v", networkInterface.Name, addresses)
		}
	}
	connection, dialErr := net.DialTimeout("tcp", "192.0.2.1:80", 500*time.Millisecond)
	if dialErr == nil {
		_ = connection.Close()
		t.Fatal("numeric external TCP dial unexpectedly succeeded")
	}

	status, err := os.ReadFile("/proc/self/status")
	if err != nil {
		t.Fatalf("read process status: %v", err)
	}
	text := string(status)
	if !strings.Contains(text, "CapEff:\t0000000000000000") {
		t.Fatalf("effective capabilities were not fully dropped:\n%s", text)
	}
	if !strings.Contains(text, "NoNewPrivs:\t1") {
		t.Fatalf("no-new-privileges is not active:\n%s", text)
	}
}

func assertWriteFails(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("forbidden"), 0o600); err == nil {
		t.Fatalf("write unexpectedly succeeded: %s", path)
	}
}
