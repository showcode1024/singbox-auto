//go:build windows

package agent

// ProbeCore is only supported on Linux /proc; unit tests on Windows inject a custom CoreProbe.
func ProbeCore(_ map[string]any, _ bool) (string, error) {
	return "", collectorErr("cannot read Linux boot identity")
}
