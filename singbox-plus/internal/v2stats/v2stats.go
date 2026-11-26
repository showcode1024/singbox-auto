package v2stats

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const (
	// DefaultAddr is the default sing-box V2Ray API address.
	DefaultAddr = "127.0.0.1:41453"
	// MaxResponseBytes caps the response body size (8 MiB).
	MaxResponseBytes = 8 << 20
	queryStatsPath   = "/v2ray.core.app.stats.command.StatsService/QueryStats"
)

// Stat represents a single V2Ray traffic statistic entry.
// Value is serialized as a quoted string to match proto3 / grpcurl JSON output.
type Stat struct {
	Name  string `json:"name"`
	Value int64  `json:"value,string"`
}

// QueryStatsResponse is the JSON output schema matching grpcurl proto3 JSON.
type QueryStatsResponse struct {
	Stat []Stat `json:"stat"`
}

// MarshalJSONBytes encodes resp as compact JSON without HTML-escaping ">>>" in stat names.
func (r QueryStatsResponse) MarshalJSONBytes() ([]byte, error) {
	out := r
	if out.Stat == nil {
		out.Stat = make([]Stat, 0)
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// Query performs a plaintext HTTP/2 (h2c) gRPC QueryStats call with reset=false.
func Query(ctx context.Context, addr string) (*QueryStatsResponse, error) {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		addr = DefaultAddr
	}

	var protocols http.Protocols
	protocols.SetUnencryptedHTTP2(true)

	transport := &http.Transport{
		Protocols: &protocols,
		Proxy:     nil,
	}
	defer transport.CloseIdleConnections()

	client := &http.Client{Transport: transport}

	// Uncompressed empty QueryStatsRequest{reset: false} = 5 zero bytes.
	reqBody := []byte{0, 0, 0, 0, 0}
	endpoint := "http://" + addr + queryStatsPath
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("build gRPC request: %w", err)
	}
	req.Header.Set("Content-Type", "application/grpc")
	req.Header.Set("TE", "trailers")
	req.Header.Set("User-Agent", "singbox-plus")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Read body fully before inspecting resp.Trailer.
	body, err := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read gRPC response: %w", err)
	}
	if len(body) > MaxResponseBytes {
		return nil, fmt.Errorf("gRPC response exceeds %d bytes", MaxResponseBytes)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected HTTP status %d from V2Ray API", resp.StatusCode)
	}

	grpcStatus := resp.Trailer.Get("Grpc-Status")
	if grpcStatus == "" {
		grpcStatus = resp.Header.Get("Grpc-Status")
	}
	grpcMessage := resp.Trailer.Get("Grpc-Message")
	if grpcMessage == "" {
		grpcMessage = resp.Header.Get("Grpc-Message")
	}
	if grpcMessage != "" {
		if decoded, decErr := url.PathUnescape(grpcMessage); decErr == nil {
			grpcMessage = decoded
		}
	}

	if grpcStatus == "" {
		return nil, errors.New("missing grpc-status trailer in response")
	}
	if grpcStatus != "0" {
		name := grpcStatusName(grpcStatus)
		if grpcMessage != "" {
			return nil, fmt.Errorf("gRPC error code %s (%s): %s", grpcStatus, name, grpcMessage)
		}
		return nil, fmt.Errorf("gRPC error code %s (%s)", grpcStatus, name)
	}

	payload, err := parseGRPCFrame(body)
	if err != nil {
		return nil, err
	}
	stats, err := decodeQueryStatsResponse(payload)
	if err != nil {
		return nil, err
	}
	return &QueryStatsResponse{Stat: stats}, nil
}

func grpcStatusName(code string) string {
	n, err := strconv.Atoi(code)
	if err != nil {
		return "Unknown"
	}
	names := [...]string{
		0:  "OK",
		1:  "Canceled",
		2:  "Unknown",
		3:  "InvalidArgument",
		4:  "DeadlineExceeded",
		5:  "NotFound",
		6:  "AlreadyExists",
		7:  "PermissionDenied",
		8:  "ResourceExhausted",
		9:  "FailedPrecondition",
		10: "Aborted",
		11: "OutOfRange",
		12: "Unimplemented",
		13: "Internal",
		14: "Unavailable",
		15: "DataLoss",
		16: "Unauthenticated",
	}
	if n >= 0 && n < len(names) {
		return names[n]
	}
	return "Unknown"
}

func parseGRPCFrame(body []byte) ([]byte, error) {
	if len(body) < 5 {
		return nil, fmt.Errorf("truncated gRPC frame header (%d bytes)", len(body))
	}
	if body[0] != 0 {
		return nil, fmt.Errorf("compressed gRPC response flag %d is not supported", body[0])
	}
	msgLen := binary.BigEndian.Uint32(body[1:5])
	rem := uint64(len(body) - 5)
	if rem < uint64(msgLen) {
		return nil, fmt.Errorf("truncated gRPC frame payload: have %d, want %d", rem, msgLen)
	}
	if rem != uint64(msgLen) {
		return nil, fmt.Errorf("unexpected trailing bytes in gRPC frame: have %d, want %d", rem, msgLen)
	}
	return body[5 : 5+msgLen], nil
}

func decodeQueryStatsResponse(data []byte) ([]Stat, error) {
	stats := make([]Stat, 0)
	b := data
	for len(b) > 0 {
		tag, n := binary.Uvarint(b)
		if n <= 0 {
			return nil, errors.New("malformed protobuf tag in QueryStatsResponse")
		}
		b = b[n:]
		fieldNum := tag >> 3
		wireType := tag & 0x7
		if fieldNum == 0 {
			return nil, errors.New("invalid protobuf field number 0")
		}

		if fieldNum == 1 && wireType == 2 {
			msg, rest, err := consumeBytes(b)
			if err != nil {
				return nil, fmt.Errorf("malformed Stat field: %w", err)
			}
			b = rest
			st, err := decodeStat(msg)
			if err != nil {
				return nil, err
			}
			stats = append(stats, st)
			continue
		}

		rest, err := skipField(b, wireType)
		if err != nil {
			return nil, err
		}
		b = rest
	}
	return stats, nil
}

func decodeStat(data []byte) (Stat, error) {
	var st Stat
	b := data
	for len(b) > 0 {
		tag, n := binary.Uvarint(b)
		if n <= 0 {
			return Stat{}, errors.New("malformed protobuf tag in Stat")
		}
		b = b[n:]
		fieldNum := tag >> 3
		wireType := tag & 0x7
		if fieldNum == 0 {
			return Stat{}, errors.New("invalid protobuf field number 0 in Stat")
		}

		switch {
		case fieldNum == 1 && wireType == 2:
			raw, rest, err := consumeBytes(b)
			if err != nil {
				return Stat{}, fmt.Errorf("malformed Stat.name: %w", err)
			}
			st.Name = string(raw)
			b = rest
		case fieldNum == 2 && wireType == 0:
			v, vn := binary.Uvarint(b)
			if vn <= 0 {
				return Stat{}, errors.New("malformed Stat.value varint")
			}
			st.Value = int64(v)
			b = b[vn:]
		default:
			rest, err := skipField(b, wireType)
			if err != nil {
				return Stat{}, err
			}
			b = rest
		}
	}
	return st, nil
}

func consumeBytes(b []byte) ([]byte, []byte, error) {
	length, n := binary.Uvarint(b)
	if n <= 0 {
		return nil, nil, errors.New("malformed length varint")
	}
	b = b[n:]
	if length > uint64(len(b)) {
		return nil, nil, errors.New("length-delimited field truncated")
	}
	return b[:length], b[length:], nil
}

func skipField(b []byte, wireType uint64) ([]byte, error) {
	switch wireType {
	case 0: // Varint
		_, n := binary.Uvarint(b)
		if n <= 0 {
			return nil, errors.New("malformed varint in unknown field")
		}
		return b[n:], nil
	case 1: // 64-bit
		if len(b) < 8 {
			return nil, errors.New("truncated 64-bit unknown field")
		}
		return b[8:], nil
	case 2: // Length-delimited
		_, rest, err := consumeBytes(b)
		return rest, err
	case 5: // 32-bit
		if len(b) < 4 {
			return nil, errors.New("truncated 32-bit unknown field")
		}
		return b[4:], nil
	default:
		return nil, fmt.Errorf("unsupported protobuf wire type %d", wireType)
	}
}
