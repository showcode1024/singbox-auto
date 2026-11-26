package v2stats

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func startH2CServer(t *testing.T, handler http.Handler) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	var protocols http.Protocols
	protocols.SetUnencryptedHTTP2(true)
	srv := &http.Server{
		Handler:   handler,
		Protocols: &protocols,
	}
	go func() {
		_ = srv.Serve(ln)
	}()
	t.Cleanup(func() {
		_ = srv.Close()
		_ = ln.Close()
	})
	return ln.Addr().String()
}

func appendTag(dst []byte, fieldNum uint64, wireType uint64) []byte {
	return binary.AppendUvarint(dst, (fieldNum<<3)|wireType)
}

func appendBytesField(dst []byte, fieldNum uint64, data []byte) []byte {
	dst = appendTag(dst, fieldNum, 2)
	dst = binary.AppendUvarint(dst, uint64(len(data)))
	return append(dst, data...)
}

func appendVarintField(dst []byte, fieldNum uint64, val uint64) []byte {
	dst = appendTag(dst, fieldNum, 0)
	return binary.AppendUvarint(dst, val)
}

func encodeStat(name string, value int64, extraUnknown bool) []byte {
	var b []byte
	if name != "" {
		b = appendBytesField(b, 1, []byte(name))
	}
	if value != 0 {
		b = appendVarintField(b, 2, uint64(value))
	}
	if extraUnknown {
		// Unknown field 9 (varint), field 10 (64-bit), field 11 (bytes), field 12 (32-bit)
		b = appendVarintField(b, 9, 999)
		b = appendTag(b, 10, 1)
		b = binary.LittleEndian.AppendUint64(b, 0x0102030405060708)
		b = appendBytesField(b, 11, []byte("ignored"))
		b = appendTag(b, 12, 5)
		b = binary.LittleEndian.AppendUint32(b, 0x11223344)
	}
	return b
}

func frameGRPC(compressed byte, payload []byte) []byte {
	out := make([]byte, 5+len(payload))
	out[0] = compressed
	binary.BigEndian.PutUint32(out[1:5], uint32(len(payload)))
	copy(out[5:], payload)
	return out
}

func TestQueryMultipleStatsAndUnknownFields(t *testing.T) {
	addr := startH2CServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Errorf("expected HTTP/2, got %s", r.Proto)
		}
		if r.URL.Path != queryStatsPath {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("Content-Type") != "application/grpc" {
			t.Errorf("unexpected content-type: %s", r.Header.Get("Content-Type"))
		}
		reqBody, _ := io.ReadAll(r.Body)
		if len(reqBody) != 5 || reqBody[0] != 0 || binary.BigEndian.Uint32(reqBody[1:5]) != 0 {
			t.Errorf("unexpected request frame: %x", reqBody)
		}

		var payload []byte
		payload = appendBytesField(payload, 1, encodeStat("user>>>alice>>>traffic>>>uplink", 12345, true))
		payload = appendBytesField(payload, 1, encodeStat("user>>>alice>>>traffic>>>downlink", 9876543210, false))
		// Top-level unknown field 7 (bytes)
		payload = appendBytesField(payload, 7, []byte("top-level-unknown"))

		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("Trailer", "Grpc-Status, Grpc-Message")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(frameGRPC(0, payload))
		w.Header().Set("Grpc-Status", "0")
	}))

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resp, err := Query(ctx, addr)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if len(resp.Stat) != 2 {
		t.Fatalf("len(Stat) = %d, want 2", len(resp.Stat))
	}
	if resp.Stat[0].Name != "user>>>alice>>>traffic>>>uplink" || resp.Stat[0].Value != 12345 {
		t.Errorf("stat[0] = %+v", resp.Stat[0])
	}
	if resp.Stat[1].Name != "user>>>alice>>>traffic>>>downlink" || resp.Stat[1].Value != 9876543210 {
		t.Errorf("stat[1] = %+v", resp.Stat[1])
	}

	rawJSON, err := resp.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes: %v", err)
	}
	wantJSON := `{"stat":[{"name":"user>>>alice>>>traffic>>>uplink","value":"12345"},{"name":"user>>>alice>>>traffic>>>downlink","value":"9876543210"}]}`
	if string(rawJSON) != wantJSON {
		t.Fatalf("JSON = %s\nwant = %s", string(rawJSON), wantJSON)
	}
}

func TestQueryEmptyStats(t *testing.T) {
	addr := startH2CServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("Trailer", "Grpc-Status")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(frameGRPC(0, nil))
		w.Header().Set("Grpc-Status", "0")
	}))

	resp, err := Query(context.Background(), addr)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	rawJSON, err := resp.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes: %v", err)
	}
	if string(rawJSON) != `{"stat":[]}` {
		t.Fatalf("JSON = %s, want {\"stat\":[]}", string(rawJSON))
	}
}

func TestQueryNonZeroGrpcStatus(t *testing.T) {
	addr := startH2CServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("Grpc-Status", "12")
		w.Header().Set("Grpc-Message", url.PathEscape("unknown service v2ray.core.app.stats.command.StatsService"))
		w.WriteHeader(http.StatusOK)
	}))

	_, err := Query(context.Background(), addr)
	if err == nil {
		t.Fatal("expected error for non-zero grpc-status")
	}
	msg := strings.ToLower(err.Error())
	if !strings.Contains(msg, "unimplemented") || !strings.Contains(msg, "unknown service") {
		t.Fatalf("error %q should include unimplemented and decoded message", err.Error())
	}
}

func TestQueryMalformedFrames(t *testing.T) {
	cases := []struct {
		name string
		body []byte
	}{
		{"truncated-header", []byte{0, 0, 1}},
		{"compressed", frameGRPC(1, []byte{1, 2, 3})},
		{"truncated-payload", []byte{0, 0, 0, 0, 10, 1, 2}},
		{"invalid-protobuf", frameGRPC(0, []byte{0x00})},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			addr := startH2CServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/grpc")
				w.Header().Set("Trailer", "Grpc-Status")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write(tc.body)
				w.Header().Set("Grpc-Status", "0")
			}))
			_, err := Query(context.Background(), addr)
			if err == nil {
				t.Fatalf("case %s expected error", tc.name)
			}
		})
	}
}

func TestQueryConnectionRefused(t *testing.T) {
	// Bind and immediately close a loopback port so dialing is refused.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	_, err = Query(ctx, addr)
	if err == nil {
		t.Fatal("expected connection error")
	}
}
