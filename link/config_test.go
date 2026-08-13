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
