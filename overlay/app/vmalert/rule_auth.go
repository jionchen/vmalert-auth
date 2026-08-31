package main

import (
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v2"

	"github.com/VictoriaMetrics/VictoriaMetrics/app/vmalert/config/fsurl"
	"github.com/VictoriaMetrics/VictoriaMetrics/lib/promauth"
)

var ruleAuthConfigPath = flag.String("rule.auth.config", "", "Optional path to a YAML file describing a single authenticated HTTP(S) rule source. Supports rule.url and rule.basic_auth.username/password_file")

type ruleAuthFile struct {
	Rule ruleAuthSource `yaml:"rule"`
	XXX  map[string]any `yaml:",inline"`
}

type ruleAuthSource struct {
	URL       string               `yaml:"url"`
	BasicAuth *ruleBasicAuthConfig `yaml:"basic_auth"`
	XXX       map[string]any       `yaml:",inline"`
}

type ruleBasicAuthConfig struct {
	Username     string         `yaml:"username"`
	PasswordFile string         `yaml:"password_file"`
	XXX          map[string]any `yaml:",inline"`
}

func initRuleAuth() (string, error) {
	if *ruleAuthConfigPath == "" {
		return "", nil
	}

	data, err := os.ReadFile(*ruleAuthConfigPath)
	if err != nil {
		return "", fmt.Errorf("cannot read -rule.auth.config=%q: %w", *ruleAuthConfigPath, err)
	}

	var cfg ruleAuthFile
	if err := yaml.UnmarshalStrict(data, &cfg); err != nil {
		return "", fmt.Errorf("cannot parse -rule.auth.config=%q: %w", *ruleAuthConfigPath, err)
	}
	if len(cfg.XXX) > 0 {
		return "", fmt.Errorf("unknown fields in rule auth config")
	}
	if len(cfg.Rule.XXX) > 0 {
		return "", fmt.Errorf("unknown fields in rule auth config rule section")
	}
	if cfg.Rule.URL == "" {
		return "", fmt.Errorf("rule.url cannot be empty")
	}
	u, err := url.Parse(cfg.Rule.URL)
	if err != nil {
		return "", fmt.Errorf("cannot parse rule.url=%q: %w", cfg.Rule.URL, err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", fmt.Errorf("unsupported scheme %q for rule.url; only http and https are supported", u.Scheme)
	}
	if u.Host == "" {
		return "", fmt.Errorf("rule.url must contain a host")
	}
	if u.User != nil {
		return "", fmt.Errorf("credentials in rule.url are not allowed when -rule.auth.config is used")
	}
	if cfg.Rule.BasicAuth == nil {
		return "", fmt.Errorf("rule.basic_auth must be set")
	}
	if len(cfg.Rule.BasicAuth.XXX) > 0 {
		return "", fmt.Errorf("unknown fields in rule.basic_auth")
	}
	if cfg.Rule.BasicAuth.Username == "" {
		return "", fmt.Errorf("rule.basic_auth.username cannot be empty")
	}
	if cfg.Rule.BasicAuth.PasswordFile == "" {
		return "", fmt.Errorf("rule.basic_auth.password_file cannot be empty")
	}

	baseDir := filepath.Dir(*ruleAuthConfigPath)
	ba := &promauth.BasicAuthConfig{
		Username:     cfg.Rule.BasicAuth.Username,
		PasswordFile: cfg.Rule.BasicAuth.PasswordFile,
	}
	authCfg, err := ba.NewConfig(baseDir)
	if err != nil {
		return "", fmt.Errorf("cannot initialize basic auth for rule.url=%q: %w", cfg.Rule.URL, err)
	}
	fsurl.RegisterAuth(cfg.Rule.URL, authCfg)
	return cfg.Rule.URL, nil
}
