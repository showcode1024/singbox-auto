package landing

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	// MaxInputBytes is the maximum accepted stdin length (16 KiB).
	MaxInputBytes = 16384
	// GenericErrorMessage is emitted when an error might otherwise expose raw input or secrets.
	GenericErrorMessage = "落地参数无效或含不支持的选项，请检查协议、认证凭据、加密方式、TLS 与分享链接参数。"
)

// SafeValidationError is a user-facing validation error whose message never embeds secrets or raw input.
type SafeValidationError struct {
	Message string
}

func (e *SafeValidationError) Error() string {
	return e.Message
}

func safeErr(msg string) error {
	return &SafeValidationError{Message: msg}
}

var (
	hostRegexp       = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$`)
	b64TextRegexp    = regexp.MustCompile(`^[A-Za-z0-9+/_-]+={0,2}$`)
	stdB64Regexp     = regexp.MustCompile(`^[A-Za-z0-9+/]+={0,2}$`)
	publicKeyRegexp  = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	shortIDRegexp    = regexp.MustCompile(`^[0-9A-Fa-f]*$`)
	digitsRegexp     = regexp.MustCompile(`^[0-9]+$`)
	uuidDashedRegexp = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)
	uuidPlainRegexp  = regexp.MustCompile(`^[0-9A-Fa-f]{32}$`)
)

var ss2022KeyLen = map[string]int{
	"2022-blake3-aes-128-gcm":        16,
	"2022-blake3-aes-256-gcm":        32,
	"2022-blake3-chacha20-poly1305":  32,
}

var ssMethods = map[string]bool{
	"2022-blake3-aes-128-gcm":       true,
	"2022-blake3-aes-256-gcm":       true,
	"2022-blake3-chacha20-poly1305": true,
	"aes-128-gcm":                   true,
	"aes-192-gcm":                   true,
	"aes-256-gcm":                   true,
	"chacha20-ietf-poly1305":        true,
	"xchacha20-ietf-poly1305":       true,
	"none":                          true,
}

var allowedFingerprints = map[string]bool{
	"chrome":     true,
	"firefox":    true,
	"edge":       true,
	"safari":     true,
	"ios":        true,
	"android":    true,
	"random":     true,
	"randomized": true,
	"360":        true,
	"qq":         true,
}

var allowedCongestion = map[string]bool{
	"bbr":      true,
	"cubic":    true,
	"new_reno": true,
}

var allowedUDPRelayMode = map[string]bool{
	"native": true,
	"quic":   true,
}

// Config is the canonical normalized landing outbound structure.
type Config struct {
	Type              string   `json:"type"`
	Server            string   `json:"server"`
	Port              int      `json:"port"`
	UUID              string   `json:"uuid,omitempty"`
	SNI               string   `json:"sni,omitempty"`
	PublicKey         string   `json:"public_key,omitempty"`
	ShortID           string   `json:"short_id,omitempty"`
	Fingerprint       string   `json:"fingerprint,omitempty"`
	Password          string   `json:"password,omitempty"`
	CongestionControl string   `json:"congestion_control,omitempty"`
	ALPN              []string `json:"alpn,omitempty"`
	Insecure          bool     `json:"insecure,omitempty"`
	UDPOverStream     bool     `json:"udp_over_stream,omitempty"`
	UDPRelayMode      string   `json:"udp_relay_mode,omitempty"`
	Username          string   `json:"username,omitempty"`
	Method            string   `json:"method,omitempty"`
}

// MarshalCanonicalJSON outputs exact canonical JSON matching write_landing_uri_parser
// (including empty string / false fields where required and omitting HTML escaping).
func (c Config) MarshalCanonicalJSON() ([]byte, error) {
	var payload any
	switch c.Type {
	case "vless":
		payload = struct {
			Type        string `json:"type"`
			Server      string `json:"server"`
			Port        int    `json:"port"`
			UUID        string `json:"uuid"`
			SNI         string `json:"sni"`
			PublicKey   string `json:"public_key"`
			ShortID     string `json:"short_id"`
			Fingerprint string `json:"fingerprint"`
		}{
			Type:        c.Type,
			Server:      c.Server,
			Port:        c.Port,
			UUID:        c.UUID,
			SNI:         c.SNI,
			PublicKey:   c.PublicKey,
			ShortID:     c.ShortID,
			Fingerprint: c.Fingerprint,
		}
	case "tuic":
		if c.UDPOverStream {
			payload = struct {
				Type              string   `json:"type"`
				Server            string   `json:"server"`
				Port              int      `json:"port"`
				UUID              string   `json:"uuid"`
				SNI               string   `json:"sni"`
				Password          string   `json:"password"`
				CongestionControl string   `json:"congestion_control"`
				ALPN              []string `json:"alpn"`
				Insecure          bool     `json:"insecure"`
				UDPOverStream     bool     `json:"udp_over_stream"`
			}{
				Type:              c.Type,
				Server:            c.Server,
				Port:              c.Port,
				UUID:              c.UUID,
				SNI:               c.SNI,
				Password:          c.Password,
				CongestionControl: c.CongestionControl,
				ALPN:              c.ALPN,
				Insecure:          c.Insecure,
				UDPOverStream:     c.UDPOverStream,
			}
		} else {
			payload = struct {
				Type              string   `json:"type"`
				Server            string   `json:"server"`
				Port              int      `json:"port"`
				UUID              string   `json:"uuid"`
				SNI               string   `json:"sni"`
				Password          string   `json:"password"`
				CongestionControl string   `json:"congestion_control"`
				ALPN              []string `json:"alpn"`
				Insecure          bool     `json:"insecure"`
				UDPOverStream     bool     `json:"udp_over_stream"`
				UDPRelayMode      string   `json:"udp_relay_mode"`
			}{
				Type:              c.Type,
				Server:            c.Server,
				Port:              c.Port,
				UUID:              c.UUID,
				SNI:               c.SNI,
				Password:          c.Password,
				CongestionControl: c.CongestionControl,
				ALPN:              c.ALPN,
				Insecure:          c.Insecure,
				UDPOverStream:     c.UDPOverStream,
				UDPRelayMode:      c.UDPRelayMode,
			}
		}
	case "socks":
		if c.Username != "" {
			payload = struct {
				Type     string `json:"type"`
				Server   string `json:"server"`
				Port     int    `json:"port"`
				Username string `json:"username"`
				Password string `json:"password"`
			}{
				Type:     c.Type,
				Server:   c.Server,
				Port:     c.Port,
				Username: c.Username,
				Password: c.Password,
			}
		} else {
			payload = struct {
				Type   string `json:"type"`
				Server string `json:"server"`
				Port   int    `json:"port"`
			}{
				Type:   c.Type,
				Server: c.Server,
				Port:   c.Port,
			}
		}
	case "shadowsocks":
		payload = struct {
			Type     string `json:"type"`
			Server   string `json:"server"`
			Port     int    `json:"port"`
			Method   string `json:"method"`
			Password string `json:"password"`
		}{
			Type:     c.Type,
			Server:   c.Server,
			Port:     c.Port,
			Method:   c.Method,
			Password: c.Password,
		}
	default:
		return nil, safeErr("仅支持 VLESS Reality、TUIC v5、SOCKS5 和 Shadowsocks")
	}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(payload); err != nil {
		return nil, safeErr(GenericErrorMessage)
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// Run reads up to MaxInputBytes+1 from r, parses either JSON or a share link,
// writes canonical JSON to w, and writes only safe error messages to errW.
func Run(r io.Reader, w, errW io.Writer, asJSON bool) int {
	raw, err := io.ReadAll(io.LimitReader(r, MaxInputBytes+1))
	if err != nil {
		_, _ = fmt.Fprintln(errW, GenericErrorMessage)
		return 1
	}
	if len(raw) > MaxInputBytes {
		_, _ = fmt.Fprintln(errW, "输入长度超过限制")
		return 1
	}
	if !utf8.Valid(raw) {
		_, _ = fmt.Fprintln(errW, GenericErrorMessage)
		return 1
	}

	var cfg Config
	if asJSON {
		cfg, err = NormalizeJSON(raw)
	} else {
		cfg, err = ParseLink(strings.TrimSpace(string(raw)))
	}
	if err != nil {
		var sve *SafeValidationError
		if errors.As(err, &sve) {
			_, _ = fmt.Fprintln(errW, sve.Message)
		} else {
			_, _ = fmt.Fprintln(errW, GenericErrorMessage)
		}
		return 1
	}

	out, err := cfg.MarshalCanonicalJSON()
	if err != nil {
		_, _ = fmt.Fprintln(errW, GenericErrorMessage)
		return 1
	}
	_, _ = fmt.Fprintln(w, string(out))
	return 0
}

func validateText(v any, field string, limit int, allowEmpty bool) (string, error) {
	s, ok := v.(string)
	if !ok {
		return "", safeErr(field + " 格式无效")
	}
	if !utf8.ValidString(s) || utf8.RuneCountInString(s) > limit || (!allowEmpty && s == "") {
		return "", safeErr(field + " 格式无效")
	}
	for _, r := range s {
		if r < 32 || r == 127 {
			return "", safeErr(field + " 格式无效")
		}
	}
	return s, nil
}

func validateHost(v any) (string, error) {
	s, err := validateText(v, "地址", 253, false)
	if err != nil {
		return "", err
	}
	if addr, parseErr := netip.ParseAddr(s); parseErr == nil && addr.Zone() == "" {
		return addr.String(), nil
	}
	if strings.Contains(s, ":") || !hostRegexp.MatchString(s) || strings.Contains(s, "..") {
		return "", safeErr("地址格式无效")
	}
	return s, nil
}

func parseBoolean(v any, field string) (bool, error) {
	switch val := v.(type) {
	case bool:
		return val, nil
	case string:
		switch strings.ToLower(val) {
		case "1", "true":
			return true, nil
		case "0", "false":
			return false, nil
		}
	case json.Number:
		switch val.String() {
		case "1":
			return true, nil
		case "0":
			return false, nil
		}
	case int:
		if val == 1 {
			return true, nil
		}
		if val == 0 {
			return false, nil
		}
	case int64:
		if val == 1 {
			return true, nil
		}
		if val == 0 {
			return false, nil
		}
	}
	return false, safeErr(field + " 必须为 0/1 或 true/false")
}

func parsePort(v any) (int, error) {
	var raw string
	switch val := v.(type) {
	case bool:
		return 0, safeErr("端口必须为 1-65535")
	case int:
		if val >= 1 && val <= 65535 {
			return val, nil
		}
		return 0, safeErr("端口必须为 1-65535")
	case int64:
		if val >= 1 && val <= 65535 {
			return int(val), nil
		}
		return 0, safeErr("端口必须为 1-65535")
	case json.Number:
		raw = val.String()
	case string:
		raw = val
	default:
		return 0, safeErr("端口必须为 1-65535")
	}
	if !digitsRegexp.MatchString(raw) {
		return 0, safeErr("端口必须为 1-65535")
	}
	p, err := strconv.Atoi(raw)
	if err != nil || p < 1 || p > 65535 {
		return 0, safeErr("端口必须为 1-65535")
	}
	return p, nil
}

func parseUUID(v any) (string, error) {
	s, err := validateText(v, "UUID", 36, false)
	if err != nil {
		return "", err
	}
	if uuidDashedRegexp.MatchString(s) {
		return strings.ToLower(s), nil
	}
	if uuidPlainRegexp.MatchString(s) {
		lo := strings.ToLower(s)
		return lo[0:8] + "-" + lo[8:12] + "-" + lo[12:16] + "-" + lo[16:20] + "-" + lo[20:32], nil
	}
	return "", safeErr("UUID 格式无效")
}

func b64DecodeText(value, field string) (string, error) {
	if value == "" || !b64TextRegexp.MatchString(value) || len(value)%4 == 1 {
		return "", safeErr(field + " Base64 格式无效")
	}
	padded := strings.NewReplacer("-", "+", "_", "/").Replace(value)
	if rem := len(padded) % 4; rem != 0 {
		padded += strings.Repeat("=", 4-rem)
	}
	decoded, err := base64.StdEncoding.DecodeString(padded)
	if err != nil || !utf8.Valid(decoded) {
		return "", safeErr(field + " Base64 解码失败")
	}
	s := string(decoded)
	for _, r := range s {
		if r < 32 || r == 127 {
			return "", safeErr(field + " 包含非法控制字符")
		}
	}
	return s, nil
}

// NormalizeJSON validates and normalizes a JSON-encoded landing configuration.
func NormalizeJSON(raw []byte) (Config, error) {
	if len(raw) > MaxInputBytes {
		return Config{}, safeErr("输入长度超过限制")
	}
	if !utf8.Valid(raw) {
		return Config{}, safeErr(GenericErrorMessage)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var parsed any
	if err := dec.Decode(&parsed); err != nil {
		return Config{}, safeErr(GenericErrorMessage)
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return Config{}, safeErr(GenericErrorMessage)
	}
	m, ok := parsed.(map[string]any)
	if !ok {
		return Config{}, safeErr("落地配置必须为 JSON 对象")
	}
	return normalizeMap(m)
}

func normalizeMap(value map[string]any) (Config, error) {
	if value == nil {
		return Config{}, safeErr("落地配置必须为 JSON 对象")
	}
	kindRaw, exists := value["type"]
	kind := "vless"
	if exists {
		s, ok := kindRaw.(string)
		if !ok {
			return Config{}, safeErr("仅支持 VLESS Reality、TUIC v5、SOCKS5 和 Shadowsocks")
		}
		kind = s
	}
	switch kind {
	case "vless", "tuic", "socks", "shadowsocks":
	default:
		return Config{}, safeErr("仅支持 VLESS Reality、TUIC v5、SOCKS5 和 Shadowsocks")
	}

	port, err := parsePort(value["port"])
	if err != nil {
		return Config{}, err
	}
	server, err := validateHost(value["server"])
	if err != nil {
		return Config{}, err
	}

	if kind == "vless" || kind == "tuic" {
		userUUID, err := parseUUID(value["uuid"])
		if err != nil {
			return Config{}, err
		}
		sniRaw := value["sni"]
		if sniRaw == nil || sniRaw == "" {
			sniRaw = server
		}
		sni, err := validateHost(sniRaw)
		if err != nil {
			return Config{}, err
		}
		cfg := Config{
			Type:   kind,
			Server: server,
			Port:   port,
			UUID:   userUUID,
			SNI:    sni,
		}
		if kind == "vless" {
			key, err := validateText(value["public_key"], "Reality PublicKey", 43, false)
			if err != nil {
				return Config{}, err
			}
			if !publicKeyRegexp.MatchString(key) {
				return Config{}, safeErr("Reality PublicKey 格式无效")
			}
			decodedKey, err := base64.URLEncoding.DecodeString(key + "=")
			if err != nil || len(decodedKey) != 32 {
				return Config{}, safeErr("Reality PublicKey 格式无效")
			}

			shortRaw, ok := value["short_id"]
			if !ok {
				shortRaw = ""
			}
			shortID, err := validateText(shortRaw, "Reality ShortID", 16, true)
			if err != nil {
				return Config{}, err
			}
			if len(shortID)%2 != 0 || !shortIDRegexp.MatchString(shortID) {
				return Config{}, safeErr("Reality ShortID 必须为最多16位的偶数长度十六进制")
			}

			fpRaw, ok := value["fingerprint"]
			fp := "chrome"
			if ok {
				s, isStr := fpRaw.(string)
				if !isStr {
					return Config{}, safeErr("不支持此 TLS 指纹")
				}
				fp = s
			}
			if !allowedFingerprints[fp] {
				return Config{}, safeErr("不支持此 TLS 指纹")
			}

			cfg.PublicKey = key
			cfg.ShortID = strings.ToLower(shortID)
			cfg.Fingerprint = fp
			return cfg, nil
		}

		// tuic
		password, err := validateText(value["password"], "TUIC 密码", 4096, false)
		if err != nil {
			return Config{}, err
		}
		ccRaw, ok := value["congestion_control"]
		cc := "bbr"
		if ok {
			s, isStr := ccRaw.(string)
			if !isStr {
				return Config{}, safeErr("拥塞控制仅支持 bbr/cubic/new_reno")
			}
			cc = s
		}
		if !allowedCongestion[cc] {
			return Config{}, safeErr("拥塞控制仅支持 bbr/cubic/new_reno")
		}

		alpnList := []string{"h3"}
		if alpnRaw, hasALPN := value["alpn"]; hasALPN {
			switch items := alpnRaw.(type) {
			case []any:
				if len(items) < 1 || len(items) > 16 {
					return Config{}, safeErr("ALPN 格式无效")
				}
				alpnList = make([]string, 0, len(items))
				for _, item := range items {
					s, err := validateText(item, "ALPN", 64, false)
					if err != nil {
						return Config{}, err
					}
					for _, r := range s {
						if unicode.IsSpace(r) {
							return Config{}, safeErr("ALPN 不能含空白")
						}
					}
					alpnList = append(alpnList, s)
				}
			case []string:
				if len(items) < 1 || len(items) > 16 {
					return Config{}, safeErr("ALPN 格式无效")
				}
				alpnList = make([]string, 0, len(items))
				for _, item := range items {
					s, err := validateText(item, "ALPN", 64, false)
					if err != nil {
						return Config{}, err
					}
					for _, r := range s {
						if unicode.IsSpace(r) {
							return Config{}, safeErr("ALPN 不能含空白")
						}
					}
					alpnList = append(alpnList, s)
				}
			default:
				return Config{}, safeErr("ALPN 格式无效")
			}
		}

		streamRaw, hasStream := value["udp_over_stream"]
		if !hasStream {
			streamRaw = false
		}
		stream, err := parseBoolean(streamRaw, "udp_over_stream")
		if err != nil {
			return Config{}, err
		}

		modeRaw, hasMode := value["udp_relay_mode"]
		mode := "native"
		if hasMode {
			s, isStr := modeRaw.(string)
			if !isStr {
				return Config{}, safeErr("UDP 转发仅支持 native/quic")
			}
			mode = s
		}
		if !allowedUDPRelayMode[mode] {
			return Config{}, safeErr("UDP 转发仅支持 native/quic")
		}
		if stream && hasMode {
			return Config{}, safeErr("udp_over_stream 与 udp_relay_mode 不能同时指定")
		}

		insecureRaw, hasInsecure := value["insecure"]
		if !hasInsecure {
			insecureRaw = false
		}
		insecure, err := parseBoolean(insecureRaw, "insecure")
		if err != nil {
			return Config{}, err
		}

		cfg.Password = password
		cfg.CongestionControl = cc
		cfg.ALPN = alpnList
		cfg.Insecure = insecure
		cfg.UDPOverStream = stream
		if !stream {
			cfg.UDPRelayMode = mode
		}
		return cfg, nil
	}

	if kind == "socks" {
		userRaw, hasUser := value["username"]
		if !hasUser {
			userRaw = ""
		}
		passRaw, hasPass := value["password"]
		if !hasPass {
			passRaw = ""
		}
		username, err := validateText(userRaw, "SOCKS5 用户名", 255, true)
		if err != nil {
			return Config{}, err
		}
		password, err := validateText(passRaw, "SOCKS5 密码", 255, true)
		if err != nil {
			return Config{}, err
		}
		if len(username) > 255 || len(password) > 255 {
			return Config{}, safeErr("SOCKS5 用户名和密码长度不能超过 255 字节")
		}
		if password != "" && username == "" {
			return Config{}, safeErr("SOCKS5 填写密码时必须同时提供用户名")
		}
		cfg := Config{
			Type:   "socks",
			Server: server,
			Port:   port,
		}
		if username != "" {
			cfg.Username = username
			cfg.Password = password
		}
		return cfg, nil
	}

	// shadowsocks
	methodRaw, err := validateText(value["method"], "Shadowsocks 加密方式", 64, false)
	if err != nil {
		return Config{}, err
	}
	method := strings.ToLower(methodRaw)
	if !ssMethods[method] {
		return Config{}, safeErr("不支持该 Shadowsocks 加密方式")
	}
	passRaw, hasPass := value["password"]
	if !hasPass {
		passRaw = ""
	}
	password, err := validateText(passRaw, "Shadowsocks 密码", 4096, method == "none")
	if err != nil {
		return Config{}, err
	}
	if keyLen, is2022 := ss2022KeyLen[method]; is2022 {
		parts := strings.Split(password, ":")
		for _, part := range parts {
			if part == "" {
				return Config{}, safeErr("SS-2022 密钥格式无效")
			}
		}
		for _, part := range parts {
			if len(part)%4 != 0 || !stdB64Regexp.MatchString(part) {
				return Config{}, safeErr("SS-2022 密钥必须为匹配长度的标准 Base64")
			}
			decoded, decErr := base64.StdEncoding.DecodeString(part)
			if decErr != nil || len(decoded) != keyLen {
				return Config{}, safeErr("SS-2022 密钥必须为匹配长度的标准 Base64")
			}
		}
	}
	return Config{
		Type:     "shadowsocks",
		Server:   server,
		Port:     port,
		Method:   method,
		Password: password,
	}, nil
}

func hasInvalidPercentEncoding(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '%' {
			if i+2 >= len(s) || !isHex(s[i+1]) || !isHex(s[i+2]) {
				return true
			}
			i += 2
		}
	}
	return false
}

func isHex(b byte) bool {
	return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

func unquoteStrict(s string) (string, error) {
	decoded, err := url.PathUnescape(s)
	if err != nil || !utf8.ValidString(decoded) {
		return "", safeErr(GenericErrorMessage)
	}
	return decoded, nil
}

func parseQueryStrict(query string) (map[string]string, error) {
	values := make(map[string]string)
	if query == "" {
		return values, nil
	}
	for _, part := range strings.Split(query, "&") {
		rawKey, rawVal, ok := strings.Cut(part, "=")
		if !ok {
			return nil, safeErr(GenericErrorMessage)
		}
		k, err := url.QueryUnescape(rawKey)
		if err != nil || !utf8.ValidString(k) {
			return nil, safeErr(GenericErrorMessage)
		}
		v, err := url.QueryUnescape(rawVal)
		if err != nil || !utf8.ValidString(v) {
			return nil, safeErr(GenericErrorMessage)
		}
		if _, dup := values[k]; dup {
			return nil, safeErr("分享链接含重复参数")
		}
		values[k] = v
	}
	return values, nil
}

type splitParts struct {
	scheme string
	netloc string
	path   string
	query  string
}

func splitURI(raw string) (splitParts, error) {
	beforeFrag, _, _ := strings.Cut(raw, "#")
	idx := strings.Index(beforeFrag, "://")
	if idx <= 0 {
		return splitParts{}, safeErr("仅支持 vless://、tuic://、socks5://、socks:// 或 ss:// 分享链接")
	}
	scheme := strings.ToLower(beforeFrag[:idx])
	rest := beforeFrag[idx+3:]
	rest, query, _ := strings.Cut(rest, "?")
	netloc := rest
	path := ""
	switch scheme {
	case "ss", "socks", "socks5", "socks5h", "tuic":
		// Credentials in userinfo (standard Base64 or raw passwords) may contain literal '/'.
		// Only split path from '/' appearing after '@' (i.e. after host:port).
		if at := strings.LastIndexByte(rest, '@'); at >= 0 {
			if slash := strings.IndexByte(rest[at+1:], '/'); slash >= 0 {
				netloc = rest[:at+1+slash]
				path = rest[at+1+slash:]
			}
		} else if scheme != "ss" {
			// Legacy full-base64 ss://<b64> has no '@' and may contain '/' in Base64;
			// other schemes without '@' have only hostport and optional path.
			if slash := strings.IndexByte(rest, '/'); slash >= 0 {
				netloc = rest[:slash]
				path = rest[slash:]
			}
		}
	default:
		if slash := strings.IndexByte(rest, '/'); slash >= 0 {
			netloc = rest[:slash]
			path = rest[slash:]
		}
	}
	return splitParts{
		scheme: scheme,
		netloc: netloc,
		path:   path,
		query:  query,
	}, nil
}

func parseHostPort(hostport string) (string, int, bool, error) {
	if hostport == "" {
		return "", 0, false, nil
	}
	var hostStr, portStr string
	if strings.HasPrefix(hostport, "[") {
		end := strings.IndexByte(hostport, ']')
		if end < 0 {
			return "", 0, false, safeErr("分享链接地址或端口无效")
		}
		hostStr = hostport[1:end]
		rem := hostport[end+1:]
		if rem == "" {
			return hostStr, 0, false, nil
		}
		if !strings.HasPrefix(rem, ":") {
			return "", 0, false, safeErr("分享链接地址或端口无效")
		}
		portStr = rem[1:]
	} else {
		colon := strings.LastIndexByte(hostport, ':')
		if colon < 0 {
			return hostport, 0, false, nil
		}
		if strings.IndexByte(hostport, ':') != colon {
			return "", 0, false, safeErr("分享链接地址或端口无效")
		}
		hostStr = hostport[:colon]
		portStr = hostport[colon+1:]
	}

	if portStr == "" {
		return hostStr, 0, false, nil
	}
	if !digitsRegexp.MatchString(portStr) {
		return "", 0, false, safeErr("分享链接地址或端口无效")
	}
	p, err := strconv.Atoi(portStr)
	if err != nil || p < 0 || p > 65535 {
		return "", 0, false, safeErr("分享链接地址或端口无效")
	}
	return hostStr, p, true, nil
}

// ParseLink parses and validates a vless://, tuic://, socks://, socks5://, socks5h://, or ss:// share URI.
func ParseLink(raw string) (Config, error) {
	raw, err := validateText(raw, "分享链接", MaxInputBytes, false)
	if err != nil {
		return Config{}, err
	}
	beforeFrag, _, _ := strings.Cut(raw, "#")
	if hasInvalidPercentEncoding(beforeFrag) {
		return Config{}, safeErr("分享链接含无效百分号编码")
	}

	parts, err := splitURI(raw)
	if err != nil {
		return Config{}, err
	}
	switch parts.scheme {
	case "tuic", "vless", "socks", "socks5", "socks5h", "ss":
	default:
		return Config{}, safeErr("仅支持 vless://、tuic://、socks5://、socks:// 或 ss:// 分享链接")
	}
	if parts.path != "" && parts.path != "/" {
		return Config{}, safeErr("仅支持 vless://、tuic://、socks5://、socks:// 或 ss:// 分享链接")
	}

	values, err := parseQueryStrict(parts.query)
	if err != nil {
		return Config{}, err
	}
	used := make(map[string]bool)

	option := func(names []string, defaultVal *string) (*string, error) {
		var found []string
		for _, n := range names {
			if _, ok := values[n]; ok {
				found = append(found, n)
				used[n] = true
			}
		}
		if len(found) > 1 {
			return nil, safeErr("分享链接同义参数重复")
		}
		if len(found) == 1 {
			v := values[found[0]]
			return &v, nil
		}
		return defaultVal, nil
	}

	requireOption := func(names []string, supported []string, defaultVal *string) error {
		sel, err := option(names, defaultVal)
		if err != nil {
			return err
		}
		if sel == nil {
			return safeErr("分享链接的 " + names[0] + " 不受支持")
		}
		lo := strings.ToLower(*sel)
		for _, s := range supported {
			if lo == s {
				return nil
			}
		}
		return safeErr("分享链接的 " + names[0] + " 不受支持")
	}

	strPtr := func(s string) *string { return &s }

	if parts.scheme == "ss" {
		if len(values) > 0 {
			typeOpt, err := option([]string{"type", "transport"}, strPtr("tcp"))
			if err != nil {
				return Config{}, err
			}
			switch strings.ToLower(*typeOpt) {
			case "", "tcp", "raw":
			default:
				return Config{}, safeErr("暂不支持 Shadowsocks 插件或附加查询参数")
			}

			secOpt, err := option([]string{"security"}, strPtr("none"))
			if err != nil {
				return Config{}, err
			}
			switch strings.ToLower(*secOpt) {
			case "", "none":
			default:
				return Config{}, safeErr("暂不支持 Shadowsocks 插件或附加查询参数")
			}

			headerOpt, err := option([]string{"headerType"}, strPtr("none"))
			if err != nil {
				return Config{}, err
			}
			switch strings.ToLower(*headerOpt) {
			case "", "none":
			default:
				return Config{}, safeErr("暂不支持 Shadowsocks 插件或附加查询参数")
			}

			pluginOpt, err := option([]string{"plugin"}, strPtr(""))
			if err != nil {
				return Config{}, err
			}
			if *pluginOpt != "" {
				return Config{}, safeErr("暂不支持 Shadowsocks 插件或附加查询参数")
			}

			uotOpt, err := option([]string{"uot"}, strPtr("0"))
			if err != nil {
				return Config{}, err
			}
			if *uotOpt != "" {
				uot, err := parseBoolean(*uotOpt, "uot")
				if err != nil || uot {
					return Config{}, safeErr("暂不支持 Shadowsocks 插件或附加查询参数")
				}
			}

			for k := range values {
				if !used[k] {
					return Config{}, safeErr("暂不支持 Shadowsocks 插件或附加查询参数")
				}
			}
		}
		var server, method, password string
		var port int
		if !strings.Contains(parts.netloc, "@") {
			unqNetloc, err := unquoteStrict(parts.netloc)
			if err != nil {
				return Config{}, err
			}
			decoded, err := b64DecodeText(unqNetloc, "Shadowsocks 链接")
			if err != nil && strings.HasSuffix(parts.netloc, "/") {
				if unqTrimmed, uErr := unquoteStrict(strings.TrimSuffix(parts.netloc, "/")); uErr == nil {
					if d, dErr := b64DecodeText(unqTrimmed, "Shadowsocks 链接"); dErr == nil {
						decoded, err = d, nil
					}
				}
			}
			if err != nil {
				return Config{}, err
			}
			at := strings.LastIndexByte(decoded, '@')
			if at < 0 {
				return Config{}, safeErr("Shadowsocks 链接缺少服务器地址")
			}
			userinfo, hostport := decoded[:at], decoded[at+1:]
			m, p, hasColon := strings.Cut(userinfo, ":")
			if !hasColon {
				return Config{}, safeErr("Shadowsocks 链接缺少加密方式或密码")
			}
			method, password = m, p
			if strings.ContainsAny(hostport, "@?#") {
				return Config{}, safeErr("Shadowsocks 地址或端口无效")
			}
			cleanHP := strings.TrimSuffix(hostport, "/")
			if strings.Contains(cleanHP, "/") {
				return Config{}, safeErr("Shadowsocks 地址或端口无效")
			}
			h, pNum, hasPort, err := parseHostPort(cleanHP)
			if err != nil || h == "" || !hasPort {
				return Config{}, safeErr("Shadowsocks 地址或端口无效")
			}
			server, port = h, pNum
		} else {
			at := strings.LastIndexByte(parts.netloc, '@')
			rawUserinfo, hostport := parts.netloc[:at], parts.netloc[at+1:]
			h, pNum, hasPort, err := parseHostPort(hostport)
			if err != nil {
				return Config{}, safeErr("Shadowsocks 地址或端口无效")
			}
			if h == "" || !hasPort {
				return Config{}, safeErr("Shadowsocks 链接缺少地址或端口")
			}
			if rawUserinfo == "" {
				return Config{}, safeErr("Shadowsocks 链接缺少认证信息")
			}
			server, port = h, pNum
			if rawMethod, rawPass, hasColon := strings.Cut(rawUserinfo, ":"); hasColon {
				method, err = unquoteStrict(rawMethod)
				if err != nil {
					return Config{}, err
				}
				password, err = unquoteStrict(rawPass)
				if err != nil {
					return Config{}, err
				}
			} else {
				unqUserinfo, err := unquoteStrict(rawUserinfo)
				if err != nil {
					return Config{}, err
				}
				if m, p, ok := strings.Cut(unqUserinfo, ":"); ok {
					method, password = m, p
				} else {
					decoded, err := b64DecodeText(unqUserinfo, "Shadowsocks 认证信息")
					if err != nil {
						return Config{}, err
					}
					m, p, ok := strings.Cut(decoded, ":")
					if !ok {
						return Config{}, safeErr("Shadowsocks 认证信息格式无效")
					}
					method, password = m, p
				}
			}
		}
		return normalizeMap(map[string]any{
			"type":     "shadowsocks",
			"server":   server,
			"port":     port,
			"method":   method,
			"password": password,
		})
	}

	// Split userinfo@hostport for non-ss schemes
	hasUserinfo := false
	rawUserinfo := ""
	hostport := parts.netloc
	if at := strings.LastIndexByte(parts.netloc, '@'); at >= 0 {
		hasUserinfo = true
		rawUserinfo = parts.netloc[:at]
		hostport = parts.netloc[at+1:]
	}

	server, port, hasPort, err := parseHostPort(hostport)
	if err != nil {
		return Config{}, err
	}
	if server == "" || !hasPort {
		return Config{}, safeErr("分享链接缺少地址或端口")
	}

	var rawUser, rawPass string
	hasPass := false
	if hasUserinfo {
		if u, p, ok := strings.Cut(rawUserinfo, ":"); ok {
			rawUser, rawPass, hasPass = u, p, true
		} else {
			rawUser = rawUserinfo
		}
	}

	if parts.scheme == "socks" || parts.scheme == "socks5" || parts.scheme == "socks5h" {
		if len(values) > 0 {
			typeOpt, err := option([]string{"type", "transport"}, strPtr("tcp"))
			if err != nil {
				return Config{}, err
			}
			switch strings.ToLower(*typeOpt) {
			case "", "tcp", "raw":
			default:
				return Config{}, safeErr("SOCKS5 分享链接包含不支持的参数")
			}

			secOpt, err := option([]string{"security"}, strPtr("none"))
			if err != nil {
				return Config{}, err
			}
			switch strings.ToLower(*secOpt) {
			case "", "none":
			default:
				return Config{}, safeErr("SOCKS5 分享链接包含不支持的参数")
			}

			headerOpt, err := option([]string{"headerType"}, strPtr("none"))
			if err != nil {
				return Config{}, err
			}
			switch strings.ToLower(*headerOpt) {
			case "", "none":
			default:
				return Config{}, safeErr("SOCKS5 分享链接包含不支持的参数")
			}

			for k := range values {
				if !used[k] {
					return Config{}, safeErr("SOCKS5 分享链接包含不支持的参数")
				}
			}
		}
		username, password := "", ""
		if hasPass && rawUser == "" {
			return Config{}, safeErr("SOCKS5 分享链接缺少用户名")
		} else if hasUserinfo && hasPass {
			username, err = unquoteStrict(rawUser)
			if err != nil {
				return Config{}, err
			}
			password, err = unquoteStrict(rawPass)
			if err != nil {
				return Config{}, err
			}
		} else if hasUserinfo {
			rawUserDec, err := unquoteStrict(rawUser)
			if err != nil {
				return Config{}, err
			}
			if parts.scheme == "socks" {
				if decoded, b64Err := b64DecodeText(rawUserDec, "SOCKS5 认证信息"); b64Err == nil {
					if u, p, ok := strings.Cut(decoded, ":"); ok {
						username, password = u, p
					} else {
						username = rawUserDec
					}
				} else {
					username = rawUserDec
				}
			} else {
				username = rawUserDec
			}
		}
		result := map[string]any{
			"type":   "socks",
			"server": server,
			"port":   port,
		}
		if username != "" || password != "" {
			result["username"] = username
			result["password"] = password
		}
		return normalizeMap(result)
	}

	// vless or tuic
	userUUID := ""
	if hasUserinfo {
		userUUID, err = unquoteStrict(rawUser)
		if err != nil {
			return Config{}, err
		}
	}
	sniOpt, err := option([]string{"sni", "serverName", "servername"}, &server)
	if err != nil {
		return Config{}, err
	}

	result := map[string]any{
		"type":   parts.scheme,
		"server": server,
		"port":   port,
		"uuid":   userUUID,
		"sni":    *sniOpt,
	}

	if parts.scheme == "vless" {
		if hasPass {
			return Config{}, safeErr("VLESS 分享链接认证格式无效")
		}
		if err := requireOption([]string{"security"}, []string{"reality"}, nil); err != nil {
			return Config{}, err
		}
		if err := requireOption([]string{"type", "transport"}, []string{"tcp", "raw", ""}, strPtr("tcp")); err != nil {
			return Config{}, err
		}
		if err := requireOption([]string{"flow"}, []string{"xtls-rprx-vision"}, nil); err != nil {
			return Config{}, err
		}
		if err := requireOption([]string{"encryption"}, []string{"none", ""}, strPtr("none")); err != nil {
			return Config{}, err
		}
		if err := requireOption([]string{"headerType"}, []string{"none", ""}, strPtr("none")); err != nil {
			return Config{}, err
		}
		if err := requireOption([]string{"packetEncoding", "packet_encoding"}, []string{"xudp", ""}, strPtr("xudp")); err != nil {
			return Config{}, err
		}
		insecureOpt, err := option([]string{"allow_insecure", "allowInsecure", "insecure"}, strPtr("0"))
		if err != nil {
			return Config{}, err
		}
		if *insecureOpt != "" {
			insecure, err := parseBoolean(*insecureOpt, "allowInsecure")
			if err != nil || insecure {
				return Config{}, safeErr("分享链接的 allowInsecure 不受支持")
			}
		}
		spxOpt, err := option([]string{"spx", "spiderX"}, strPtr(""))
		if err != nil {
			return Config{}, err
		}
		if _, err := validateText(*spxOpt, "Reality spx", 256, true); err != nil {
			return Config{}, err
		}
		pbkOpt, err := option([]string{"pbk", "publicKey", "public_key"}, nil)
		if err != nil {
			return Config{}, err
		}
		sidOpt, err := option([]string{"sid", "shortId", "short_id"}, strPtr(""))
		if err != nil {
			return Config{}, err
		}
		fpOpt, err := option([]string{"fp", "fingerprint"}, strPtr("chrome"))
		if err != nil {
			return Config{}, err
		}
		fp := strings.ToLower(*fpOpt)
		if fp == "" {
			fp = "chrome"
		}
		if pbkOpt != nil {
			result["public_key"] = *pbkOpt
		}
		result["short_id"] = *sidOpt
		result["fingerprint"] = fp
	} else {
		// tuic
		tuicPass := ""
		if hasPass {
			tuicPass, err = unquoteStrict(rawPass)
			if err != nil {
				return Config{}, err
			}
		}
		result["password"] = tuicPass
		if err := requireOption([]string{"version", "v"}, []string{"5", ""}, strPtr("5")); err != nil {
			return Config{}, err
		}
		ccOpt, err := option([]string{"congestion_control", "congestion-controller", "congestion-control", "congestionControl"}, strPtr("bbr"))
		if err != nil {
			return Config{}, err
		}
		cc := strings.ToLower(*ccOpt)
		if cc == "" {
			cc = "bbr"
		}
		insecureOpt, err := option([]string{"allow_insecure", "allowInsecure", "insecure", "skip-cert-verify", "skip_cert_verify"}, strPtr("0"))
		if err != nil {
			return Config{}, err
		}
		insecureVal := *insecureOpt
		if insecureVal == "" {
			insecureVal = "0"
		}
		alpnOpt, err := option([]string{"alpn"}, strPtr("h3"))
		if err != nil {
			return Config{}, err
		}
		alpnVal := *alpnOpt
		if alpnVal == "" {
			alpnVal = "h3"
		}
		disableSNIOpt, err := option([]string{"disable_sni", "disable-sni", "disableSni", "disableSNI"}, strPtr("0"))
		if err != nil {
			return Config{}, err
		}
		disableSNIVal := *disableSNIOpt
		if disableSNIVal == "" {
			disableSNIVal = "0"
		}
		disableSNI, err := parseBoolean(disableSNIVal, "disable_sni")
		if err != nil {
			return Config{}, err
		}
		if disableSNI {
			return Config{}, safeErr("不支持 disable_sni=1，请使用 SNI")
		}
		zeroRTTOpt, err := option([]string{"zero_rtt_handshake", "zero-rtt-handshake", "zeroRttHandshake", "zeroRTTHandshake", "reduce_rtt", "reduce-rtt", "reduceRtt"}, strPtr("0"))
		if err != nil {
			return Config{}, err
		}
		zeroRTTVal := *zeroRTTOpt
		if zeroRTTVal == "" {
			zeroRTTVal = "0"
		}
		zeroRTT, err := parseBoolean(zeroRTTVal, "zero_rtt_handshake")
		if err != nil {
			return Config{}, err
		}
		if zeroRTT {
			return Config{}, safeErr("不支持启用 0-RTT")
		}
		streamOpt, err := option([]string{"udp_over_stream", "udp-over-stream", "udpOverStream"}, strPtr("0"))
		if err != nil {
			return Config{}, err
		}
		streamVal := *streamOpt
		if streamVal == "" {
			streamVal = "0"
		}
		stream, err := parseBoolean(streamVal, "udp_over_stream")
		if err != nil {
			return Config{}, err
		}
		modeOpt, err := option([]string{"udp_relay_mode", "udp-relay-mode", "udpRelayMode"}, nil)
		if err != nil {
			return Config{}, err
		}

		result["congestion_control"] = cc
		result["insecure"] = insecureVal
		result["alpn"] = strings.Split(alpnVal, ",")
		result["udp_over_stream"] = stream
		if modeOpt != nil && *modeOpt != "" {
			result["udp_relay_mode"] = strings.ToLower(*modeOpt)
		}
	}

	for k := range values {
		if !used[k] {
			return Config{}, safeErr("分享链接包含当前不支持的连接参数，请改为手动填写")
		}
	}
	return normalizeMap(result)
}
