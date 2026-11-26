package landing

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func testRealityPubKey() string {
	raw := make([]byte, 32)
	for i := range raw {
		raw[i] = byte(i + 1)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

func testSS2022Key(n int, fill byte) string {
	raw := bytes.Repeat([]byte{fill}, n)
	return base64.StdEncoding.EncodeToString(raw)
}

func TestParseVLESSReality3xUI(t *testing.T) {
	pbk := testRealityPubKey()
	link := "vless://550E8400-E29B-41D4-A716-446655440000@203.0.113.10:443" +
		"?type=tcp&security=reality&pbk=" + pbk +
		"&fp=chrome&sni=www.example.com&sid=AABB1122&spx=%2F&flow=xtls-rprx-vision&packetEncoding=xudp#my-node%zz"

	cfg, err := ParseLink(link)
	if err != nil {
		t.Fatalf("ParseLink: %v", err)
	}
	raw, err := cfg.MarshalCanonicalJSON()
	if err != nil {
		t.Fatalf("MarshalCanonicalJSON: %v", err)
	}
	want := `{"type":"vless","server":"203.0.113.10","port":443,"uuid":"550e8400-e29b-41d4-a716-446655440000","sni":"www.example.com","public_key":"` + pbk + `","short_id":"aabb1122","fingerprint":"chrome"}`
	if string(raw) != want {
		t.Fatalf("JSON =\n%s\nwant =\n%s", string(raw), want)
	}
}

func TestParseVLESSValidationErrors(t *testing.T) {
	pbk := testRealityPubKey()
	base := "vless://550e8400-e29b-41d4-a716-446655440000@example.com:443?security=reality&flow=xtls-rprx-vision&pbk=" + pbk

	cases := []struct {
		name string
		link string
	}{
		{"password-present", "vless://550e8400-e29b-41d4-a716-446655440000:secret@example.com:443?security=reality&flow=xtls-rprx-vision&pbk=" + pbk},
		{"unknown-param", base + "&extra=1"},
		{"duplicate-param", base + "&fp=chrome&fp=firefox"},
		{"synonym-duplicate", base + "&sni=a.com&serverName=b.com"},
		{"synonym-spx-duplicate", base + "&spx=%2F&spiderX=%2F"},
		{"invalid-percent", base + "&spx=%2G"},
		{"bad-pbk-len", "vless://550e8400-e29b-41d4-a716-446655440000@example.com:443?security=reality&flow=xtls-rprx-vision&pbk=short"},
		{"odd-sid", base + "&sid=abc"},
		{"bad-fp", base + "&fp=ie6"},
		{"bad-packet-encoding", base + "&packet_encoding=packetaddr"},
		{"bad-header-type", base + "&headerType=http"},
		{"spx-too-long", base + "&spx=" + strings.Repeat("a", 257)},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseLink(tc.link)
			if err == nil {
				t.Fatalf("expected error for %s", tc.name)
			}
			var sve *SafeValidationError
			if !errors.As(err, &sve) {
				t.Errorf("expected SafeValidationError, got %T: %v", err, err)
			}
			if strings.Contains(err.Error(), "secret") || strings.Contains(err.Error(), pbk) {
				t.Errorf("error leaked sensitive data: %q", err.Error())
			}
		})
	}
}

func TestParseTUICv5(t *testing.T) {
	t.Run("default-native", func(t *testing.T) {
		link := "tuic://550e8400-e29b-41d4-a716-446655440000:p%40ss%26word@tuic.example.com:8443?congestion_control=bbr&alpn=h3,h2&allow_insecure=1&udp_relay_mode=quic"
		cfg, err := ParseLink(link)
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		raw, err := cfg.MarshalCanonicalJSON()
		if err != nil {
			t.Fatalf("MarshalCanonicalJSON: %v", err)
		}
		// Must preserve '&' unescaped, include udp_relay_mode.
		if !strings.Contains(string(raw), `"password":"p@ss&word"`) {
			t.Fatalf("password not preserved verbatim: %s", string(raw))
		}
		if !strings.Contains(string(raw), `"udp_relay_mode":"quic"`) {
			t.Fatalf("missing udp_relay_mode: %s", string(raw))
		}
		if !strings.Contains(string(raw), `"insecure":true`) {
			t.Fatalf("expected insecure:true: %s", string(raw))
		}
	})

	t.Run("udp-over-stream-omits-relay-mode", func(t *testing.T) {
		link := "tuic://550e8400-e29b-41d4-a716-446655440000:pw@tuic.example.com:8443?udp_over_stream=1"
		cfg, err := ParseLink(link)
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		raw, err := cfg.MarshalCanonicalJSON()
		if err != nil {
			t.Fatalf("MarshalCanonicalJSON: %v", err)
		}
		if strings.Contains(string(raw), "udp_relay_mode") {
			t.Fatalf("udp_relay_mode must be omitted when udp_over_stream=true: %s", string(raw))
		}
	})

	t.Run("rejects-mutually-exclusive-and-unsupported", func(t *testing.T) {
		badLinks := []string{
			"tuic://550e8400-e29b-41d4-a716-446655440000:pw@tuic.example.com:8443?udp_over_stream=1&udp_relay_mode=native",
			"tuic://550e8400-e29b-41d4-a716-446655440000:pw@tuic.example.com:8443?disable_sni=1",
			"tuic://550e8400-e29b-41d4-a716-446655440000:pw@tuic.example.com:8443?zero_rtt_handshake=1",
			"tuic://550e8400-e29b-41d4-a716-446655440000:pw@tuic.example.com:8443?alpn=h3,%20h2",
			"tuic://550e8400-e29b-41d4-a716-446655440000:pw@tuic.example.com:8443?version=4",
		}
		for _, link := range badLinks {
			if _, err := ParseLink(link); err == nil {
				t.Errorf("expected error for %s", link)
			}
		}
	})
}

func TestParseSOCKS(t *testing.T) {
	t.Run("unauthenticated-omits-creds", func(t *testing.T) {
		cfg, err := ParseLink("socks5://198.51.100.2:1080")
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		raw, err := cfg.MarshalCanonicalJSON()
		if err != nil {
			t.Fatalf("MarshalCanonicalJSON: %v", err)
		}
		want := `{"type":"socks","server":"198.51.100.2","port":1080}`
		if string(raw) != want {
			t.Fatalf("JSON = %s, want %s", string(raw), want)
		}
	})

	t.Run("socks-base64-fallback", func(t *testing.T) {
		cred := base64.StdEncoding.EncodeToString([]byte("alice:p@ss:word"))
		cfg, err := ParseLink("socks://" + cred + "@198.51.100.2:1080")
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		if cfg.Username != "alice" || cfg.Password != "p@ss:word" {
			t.Fatalf("got user=%q pass=%q", cfg.Username, cfg.Password)
		}
	})

	t.Run("socks5-no-base64-fallback", func(t *testing.T) {
		cred := base64.StdEncoding.EncodeToString([]byte("alice:secret"))
		cfg, err := ParseLink("socks5://" + cred + "@198.51.100.2:1080")
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		if cfg.Username != cred || cfg.Password != "" {
			t.Fatalf("socks5 should not base64-decode username: got user=%q pass=%q", cfg.Username, cfg.Password)
		}
	})

	t.Run("rejects-query-and-pass-without-user", func(t *testing.T) {
		if _, err := ParseLink("socks5://198.51.100.2:1080?foo=bar"); err == nil {
			t.Error("expected error for query params on socks5")
		}
		if _, err := ParseLink("socks5://:onlypass@198.51.100.2:1080"); err == nil {
			t.Error("expected error for password without username")
		}
	})
}

func TestParseShadowsocks(t *testing.T) {
	t.Run("legacy-full-base64", func(t *testing.T) {
		payload := base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:my-secret@[2001:db8::1]:8388"))
		cfg, err := ParseLink("ss://" + payload)
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		if cfg.Server != "2001:db8::1" || cfg.Port != 8388 || cfg.Method != "aes-256-gcm" || cfg.Password != "my-secret" {
			t.Fatalf("unexpected cfg: %+v", cfg)
		}
	})

	t.Run("sip002-base64-userinfo", func(t *testing.T) {
		userinfo := base64.RawURLEncoding.EncodeToString([]byte("chacha20-ietf-poly1305:pw:with:colon"))
		cfg, err := ParseLink("ss://" + userinfo + "@ss.example.com:8388")
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		if cfg.Method != "chacha20-ietf-poly1305" || cfg.Password != "pw:with:colon" {
			t.Fatalf("unexpected cfg: %+v", cfg)
		}
	})

	t.Run("ss2022-multi-user-key", func(t *testing.T) {
		k1 := testSS2022Key(16, 0x11)
		k2 := testSS2022Key(16, 0x22)
		link := "ss://2022-blake3-aes-128-gcm:" + k1 + "%3A" + k2 + "@198.51.100.5:8388"
		cfg, err := ParseLink(link)
		if err != nil {
			t.Fatalf("ParseLink: %v", err)
		}
		if cfg.Method != "2022-blake3-aes-128-gcm" || cfg.Password != k1+":"+k2 {
			t.Fatalf("unexpected cfg: %+v", cfg)
		}
	})

	t.Run("ss2022-wrong-key-length-and-query", func(t *testing.T) {
		badKey := testSS2022Key(16, 0xaa) // 16 bytes for aes-256 (needs 32)
		if _, err := ParseLink("ss://2022-blake3-aes-256-gcm:" + badKey + "@198.51.100.5:8388"); err == nil {
			t.Error("expected error for mismatched SS-2022 key length")
		}
		if _, err := ParseLink("ss://aes-128-gcm:pw@198.51.100.5:8388?plugin=obfs"); err == nil {
			t.Error("expected error for ss query plugin")
		}
	})
}

func TestNormalizeJSONAndSecretRedaction(t *testing.T) {
	t.Run("valid-json", func(t *testing.T) {
		in := `{"type":"shadowsocks","server":"1.2.3.4","port":"8388","method":"none","password":""}`
		var outBuf, errBuf bytes.Buffer
		code := Run(strings.NewReader(in), &outBuf, &errBuf, true)
		if code != 0 {
			t.Fatalf("Run failed (%d): %s", code, errBuf.String())
		}
		var parsed map[string]any
		if err := json.Unmarshal(outBuf.Bytes(), &parsed); err != nil {
			t.Fatalf("invalid output json: %v", err)
		}
		if parsed["method"] != "none" || parsed["password"] != "" {
			t.Fatalf("unexpected parsed: %+v", parsed)
		}
	})

	t.Run("malformed-json-does-not-leak-secret", func(t *testing.T) {
		secret := "SUPER_SECRET_PASSWORD_99999"
		in := `{"type":"tuic","password":"` + secret + `", broken}`
		var outBuf, errBuf bytes.Buffer
		code := Run(strings.NewReader(in), &outBuf, &errBuf, true)
		if code == 0 {
			t.Fatal("expected failure on malformed JSON")
		}
		if strings.Contains(errBuf.String(), secret) {
			t.Fatalf("stderr leaked secret: %q", errBuf.String())
		}
	})

	t.Run("malformed-query-does-not-leak-secret", func(t *testing.T) {
		secret := "TOP_SECRET_CRED_12345"
		in := "tuic://550e8400-e29b-41d4-a716-446655440000:" + secret + "@example.com:443?malformed_no_equals"
		var outBuf, errBuf bytes.Buffer
		code := Run(strings.NewReader(in), &outBuf, &errBuf, false)
		if code == 0 {
			t.Fatal("expected failure on malformed query")
		}
		if strings.Contains(errBuf.String(), secret) {
			t.Fatalf("stderr leaked secret: %q", errBuf.String())
		}
	})

	t.Run("oversized-input-rejected", func(t *testing.T) {
		in := strings.Repeat("a", MaxInputBytes+10)
		var outBuf, errBuf bytes.Buffer
		code := Run(strings.NewReader(in), &outBuf, &errBuf, false)
		if code == 0 {
			t.Fatal("expected failure for oversized input")
		}
		if errBuf.Len() == 0 {
			t.Fatal("expected error message on stderr")
		}
	})
}
