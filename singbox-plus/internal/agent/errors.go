package agent

import "fmt"

// AgentError is the base error for agent configuration, helper, and workflow failures.
type AgentError struct {
	Msg string
}

func (e *AgentError) Error() string { return e.Msg }

// CollectorError indicates a failure sampling sing-box counters or core identity.
type CollectorError struct {
	Msg string
}

func (e *CollectorError) Error() string { return e.Msg }

// LockBusy indicates another agent process holds the local file lock.
type LockBusy struct {
	Msg string
}

func (e *LockBusy) Error() string { return e.Msg }

// TransportError indicates an HTTP/HTTPS communication error with an optional status code.
type TransportError struct {
	Status int
	Msg    string
}

func (e *TransportError) Error() string { return e.Msg }

func agentErr(format string, args ...any) error {
	return &AgentError{Msg: fmt.Sprintf(format, args...)}
}

func collectorErr(format string, args ...any) error {
	return &CollectorError{Msg: fmt.Sprintf(format, args...)}
}
