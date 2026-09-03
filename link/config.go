package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var errNoDialEndpoints = errors.New("config has no remote mailbox peer for link dial")

var (
	nodePattern       = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	basePattern       = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.\-@]*$`)
	messageIDPattern  = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+\.[a-z0-9][a-z0-9-]*@[a-z0-9][a-z0-9-]*$`)
	generationPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
)

type config struct {
	self        string
	retainDays  uint64
	ttl         int64
	earsEnabled bool
	mailboxes   []string
	peers       map[string][]string
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
	c := config{retainDays: 30, ttl: 120, earsEnabled: true, peers: make(map[string][]string)}
	retainSet := false
	ttlSet := false
	earsSet := false
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
		case "ttl":
			if len(fields) != 2 || ttlSet {
				return config{}, errorsf("config ttl must be exactly one positive integer")
			}
			ttl, err := strconv.ParseInt(fields[1], 10, 64)
			if err != nil || ttl <= 0 {
				return config{}, errorsf("config ttl must be a positive integer")
			}
			c.ttl = ttl
			ttlSet = true
		case "ears":
			if len(fields) != 2 || earsSet || (fields[1] != "on" && fields[1] != "off") {
				return config{}, errorsf("config ears must be exactly one of on or off")
			}
			c.earsEnabled = fields[1] == "on"
			earsSet = true
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
		return nil, errNoDialEndpoints
	}
	return endpoints, nil
}

func validNode(s string) bool { return nodePattern.MatchString(s) }

func isReservedIdentity(identity string) bool {
	return identity == "conduit" || identity == "khala" || identity == "gateway" || identity == "operator" || identity == "khala-gateway"
}

func validBasename(s string) bool {
	return basePattern.MatchString(s) && !strings.HasPrefix(s, ".") && !strings.Contains(s, "/") && s != ".."
}

func validMessageID(s string) bool { return messageIDPattern.MatchString(s) }

func validGeneration(s string) bool { return generationPattern.MatchString(s) }

func presenceNode(name string) (string, bool) {
	base := name
	for _, suffix := range []string{".watching", ".watcher", ".ear"} {
		if strings.HasSuffix(base, suffix) {
			base = strings.TrimSuffix(base, suffix)
			break
		}
	}
	i := strings.LastIndexByte(base, '@')
	if i <= 0 || i == len(base)-1 {
		return "", false
	}
	node := base[i+1:]
	return node, validNode(node) && validBasename(name)
}

func errorsf(format string, args ...any) error { return fmt.Errorf(format, args...) }
