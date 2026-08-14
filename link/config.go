package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	nodePattern       = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	basePattern       = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.\-@]*$`)
	messageIDPattern  = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+\.[a-z0-9][a-z0-9-]*@[a-z0-9][a-z0-9-]*$`)
	generationPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
)

type config struct {
	self       string
	retainDays uint64
	mailboxes  []string
	peers      map[string][]string
}

type dialEndpoint struct {
	node    string
	address string
}

func loadConfig(home string) (config, error) {
	f, err := os.Open(filepath.Join(home, "config"))
	if err != nil {
		return config{}, fmt.Errorf("read config: %w", err)
	}
	defer f.Close()
	c := config{retainDays: 30, peers: make(map[string][]string)}
	retainSet := false
	s := bufio.NewScanner(f)
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		switch fields[0] {
		case "self":
			if len(fields) == 2 {
				c.self = fields[1]
			}
		case "mailbox":
			if len(fields) > 1 {
				c.mailboxes = append(c.mailboxes, fields[1:]...)
			}
		case "peer":
			if len(fields) > 2 {
				c.peers[fields[1]] = append(c.peers[fields[1]], fields[2:]...)
			}
		case "retain":
			if len(fields) != 2 || retainSet {
				return config{}, errorsf("config retain must be exactly one non-negative integer")
			}
			days, err := strconv.ParseUint(fields[1], 10, 64)
			if err != nil {
				return config{}, errorsf("config retain must be a non-negative integer")
			}
			c.retainDays = days
			retainSet = true
		}
	}
	if err := s.Err(); err != nil {
		return config{}, fmt.Errorf("scan config: %w", err)
	}
	if !validNode(c.self) {
		return config{}, errorsf("config self is missing or invalid")
	}
	return c, nil
}

func (c config) dialEndpoints() ([]dialEndpoint, error) {
	var endpoints []dialEndpoint
	for _, mailbox := range c.mailboxes {
		if !validNode(mailbox) {
			return nil, errorsf("config mailbox %q is invalid", mailbox)
		}
		if mailbox == c.self {
			continue
		}
		for _, endpoint := range c.peers[mailbox] {
			if filepath.IsAbs(endpoint) {
				return nil, errorsf("link refuses local-path peer %q; production carrier is ssh and tests must select the direct carrier explicitly", endpoint)
			}
			endpoints = append(endpoints, dialEndpoint{node: mailbox, address: endpoint})
		}
	}
	if len(endpoints) == 0 {
		return nil, errorsf("config has no remote mailbox peer for link dial")
	}
	return endpoints, nil
}

func validNode(s string) bool { return nodePattern.MatchString(s) }

func validBasename(s string) bool {
	return basePattern.MatchString(s) && !strings.HasPrefix(s, ".") && !strings.Contains(s, "/") && s != ".."
}

func validMessageID(s string) bool { return messageIDPattern.MatchString(s) }

func validGeneration(s string) bool { return generationPattern.MatchString(s) }

func presenceNode(name string) (string, bool) {
	base := strings.TrimSuffix(name, ".watching")
	i := strings.LastIndexByte(base, '@')
	if i <= 0 || i == len(base)-1 {
		return "", false
	}
	node := base[i+1:]
	return node, validNode(node) && validBasename(name)
}

func errorsf(format string, args ...any) error { return fmt.Errorf(format, args...) }
