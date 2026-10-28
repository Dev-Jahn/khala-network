package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
)

// runtimeHolders prints every live registration of an identity, one per line,
// and nothing when no live session holds the name:
//
//	<instance> <harness> <kind> <pid>
//
// The Claude plugin binds a subagent that declared KHALA_SESSION=<name> (D18
// r3 (D)) only when this prints nothing: a second receiver would split one
// inbox, and the main session that owns the name would lose its letters to a
// subagent. Live is what the conduit uses (registrationLive): the registered
// process runs, or the registration is under 30 s old and has no pid yet.
func runtimeHolders(args []string) error {
	fs := flag.NewFlagSet("runtime holders", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	identity := fs.String("identity", "", "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || !validNode(*identity) {
		return errors.New("holders needs --identity <name>")
	}
	root, err := runtimeRoot()
	if err != nil {
		return err
	}
	bootID, err := currentBootID()
	if err != nil {
		return err
	}
	regs, err := loadRegistrations(root, bootID)
	if err != nil {
		return err
	}
	instances := make([]string, 0, len(regs))
	for instance, reg := range regs {
		if reg.Identity == *identity && registrationLive(reg, bootID) {
			instances = append(instances, instance)
		}
	}
	sort.Strings(instances)
	for _, instance := range instances {
		reg := regs[instance]
		fmt.Fprintf(os.Stdout, "%s %s %s %d\n", instance, firstNonempty(reg.Harness, "claude"),
			firstNonempty(reg.Kind, "unknown"), reg.PID)
	}
	return nil
}
