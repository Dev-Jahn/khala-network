package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigRetainDays(t *testing.T) {
	for _, test := range []struct {
		name    string
		line    string
		want    uint64
		wantErr bool
	}{
		{name: "default", want: 30},
		{name: "configured", line: "retain 7\n", want: 7},
		{name: "zero", line: "retain 0\n", want: 0},
		{name: "negative", line: "retain -1\n", wantErr: true},
		{name: "nonnumeric", line: "retain many\n", wantErr: true},
		{name: "duplicate", line: "retain 7\nretain 8\n", wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			home := testKhalaHome(t)
			contents := "self alpha\n" + test.line
			if err := os.WriteFile(filepath.Join(home, "config"), []byte(contents), 0600); err != nil {
				t.Fatal(err)
			}
			got, err := loadConfig(home)
			if test.wantErr {
				if err == nil {
					t.Fatalf("loadConfig accepted %q", test.line)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.retainDays != test.want {
				t.Fatalf("retainDays=%d want %d", got.retainDays, test.want)
			}
		})
	}
}

func TestLoadConfigTTL(t *testing.T) {
	for _, test := range []struct {
		name    string
		line    string
		want    int64
		wantErr bool
	}{
		{name: "default", want: 120},
		{name: "configured", line: "ttl 300\n", want: 300},
		{name: "zero", line: "ttl 0\n", wantErr: true},
		{name: "negative", line: "ttl -1\n", wantErr: true},
		{name: "nonnumeric", line: "ttl often\n", wantErr: true},
		{name: "duplicate", line: "ttl 120\nttl 121\n", wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			home := testKhalaHome(t)
			if err := os.WriteFile(filepath.Join(home, "config"), []byte("self alpha\n"+test.line), 0600); err != nil {
				t.Fatal(err)
			}
			got, err := loadConfig(home)
			if test.wantErr && err == nil {
				t.Fatalf("loadConfig accepted %q", test.line)
			}
			if !test.wantErr && (err != nil || got.ttl != test.want) {
				t.Fatalf("ttl=%d want=%d err=%v", got.ttl, test.want, err)
			}
		})
	}
}

func TestLoadConfigEarsSwitch(t *testing.T) {
	for _, test := range []struct {
		name    string
		line    string
		enabled bool
		wantErr bool
	}{
		{name: "default", enabled: true},
		{name: "on", line: "ears on\n", enabled: true},
		{name: "off", line: "ears off\n"},
		{name: "invalid", line: "ears maybe\n", wantErr: true},
		{name: "duplicate", line: "ears on\nears off\n", wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			home := testKhalaHome(t)
			if err := os.WriteFile(filepath.Join(home, "config"), []byte("self alpha\n"+test.line), 0600); err != nil {
				t.Fatal(err)
			}
			got, err := loadConfig(home)
			if test.wantErr != (err != nil) {
				t.Fatalf("loadConfig err=%v wantErr=%t", err, test.wantErr)
			}
			if err == nil && got.earsEnabled != test.enabled {
				t.Fatalf("earsEnabled=%t want=%t", got.earsEnabled, test.enabled)
			}
		})
	}
}

func TestGenerationValidationMatchesBrainGrammar(t *testing.T) {
	for _, generation := range []string{"0.0", "1.0", "1786655513.42"} {
		if !validGeneration(generation) {
			t.Errorf("valid generation rejected: %q", generation)
		}
	}
	for _, generation := range []string{"", "1", "1.2.3", "01.2", "1.02", "-1.0", "a.0"} {
		if validGeneration(generation) {
			t.Errorf("invalid generation accepted: %q", generation)
		}
	}
}

func TestPresenceNodeAcceptsMarkerSuffixes(t *testing.T) {
	for _, name := range []string{
		"ear@alpha", "ear@alpha.watching", "gpu-guard@alpha.watcher", "steno@alpha.ear",
	} {
		node, ok := presenceNode(name)
		if !ok || node != "alpha" {
			t.Errorf("presenceNode(%q)=(%q, %t), want (alpha, true)", name, node, ok)
		}
	}
}
