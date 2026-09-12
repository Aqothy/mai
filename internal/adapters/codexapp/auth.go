package codexapp

import (
	"context"
	"fmt"

	"github.com/Aqothy/maiD/internal/provider"
)

const (
	authMethodChatGPT = "chatgpt"
	authMethodDevice  = "chatgpt-device-code"
	authMethodAPIKey  = "api-key"
)

func codexAuthMethods() []provider.AuthMethod {
	return []provider.AuthMethod{
		{ID: authMethodChatGPT, Name: "Continue with ChatGPT", Description: "Sign in in your browser", Kind: "browser"},
		{ID: authMethodDevice, Name: "ChatGPT device code", Description: "Sign in with a one-time code", Kind: "device-code"},
		{ID: authMethodAPIKey, Name: "OpenAI API key", Description: "Use an API key for this Codex installation", Kind: "secret", RequiresSecret: true},
	}
}

func (h *Instance) refreshAccount(ctx context.Context) error {
	var response struct {
		Account *struct {
			Type string `json:"type"`
		} `json:"account"`
		RequiresOpenAIAuth bool `json:"requiresOpenaiAuth"`
	}
	if err := h.rpc.call(ctx, "account/read", map[string]any{"refreshToken": false}, &response); err != nil {
		return err
	}
	status := provider.AuthStatusUnauthenticated
	if response.Account != nil {
		status = provider.AuthStatusAuthenticated
	} else if !response.RequiresOpenAIAuth {
		status = provider.AuthStatusUnknown
	}
	h.mu.Lock()
	h.info.Auth = provider.Auth{Status: status, Methods: codexAuthMethods()}
	h.mu.Unlock()
	return nil
}

func (h *Instance) AuthenticateWithInput(ctx context.Context, input provider.AuthenticateInput) (provider.AuthenticationResult, error) {
	var params map[string]any
	expectedResponseType := ""
	switch input.MethodID {
	case authMethodChatGPT:
		params = map[string]any{"type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"}
		expectedResponseType = "chatgpt"
	case authMethodDevice:
		params = map[string]any{"type": "chatgptDeviceCode"}
		expectedResponseType = "chatgptDeviceCode"
	case authMethodAPIKey:
		if input.Secret == "" {
			return provider.AuthenticationResult{}, fmt.Errorf("API-key authentication requires a secret")
		}
		params = map[string]any{"type": "apiKey", "apiKey": input.Secret}
		expectedResponseType = "apiKey"
	default:
		return provider.AuthenticationResult{}, fmt.Errorf("Codex authentication method %q is not supported", input.MethodID)
	}
	var response struct {
		Type            string `json:"type"`
		LoginID         string `json:"loginId"`
		AuthURL         string `json:"authUrl"`
		VerificationURL string `json:"verificationUrl"`
		UserCode        string `json:"userCode"`
	}
	if err := h.rpc.call(ctx, "account/login/start", params, &response); err != nil {
		return provider.AuthenticationResult{}, err
	}
	if response.Type != expectedResponseType {
		return provider.AuthenticationResult{}, fmt.Errorf("account/login/start returned type %q for %q authentication", response.Type, input.MethodID)
	}
	var challenge *provider.AuthChallenge
	switch response.Type {
	case "chatgpt":
		if response.LoginID == "" || response.AuthURL == "" {
			return provider.AuthenticationResult{}, fmt.Errorf("account/login/start returned an incomplete ChatGPT browser challenge")
		}
		challenge = &provider.AuthChallenge{Kind: "browser", LoginID: response.LoginID, URL: response.AuthURL}
	case "chatgptDeviceCode":
		if response.LoginID == "" || response.VerificationURL == "" || response.UserCode == "" {
			return provider.AuthenticationResult{}, fmt.Errorf("account/login/start returned an incomplete ChatGPT device-code challenge")
		}
		challenge = &provider.AuthChallenge{Kind: "device-code", LoginID: response.LoginID, URL: response.VerificationURL, VerificationURL: response.VerificationURL, UserCode: response.UserCode}
	case "apiKey":
		if err := h.refreshAccount(ctx); err != nil {
			return provider.AuthenticationResult{}, err
		}
	}
	return provider.AuthenticationResult{Instance: h.Info(), Challenge: challenge}, nil
}

func (h *Instance) Logout(ctx context.Context) (provider.InstanceInfo, error) {
	if err := h.rpc.call(ctx, "account/logout", nil, nil); err != nil {
		return provider.InstanceInfo{}, err
	}
	if err := h.refreshAccount(ctx); err != nil {
		return provider.InstanceInfo{}, err
	}
	return h.Info(), nil
}
