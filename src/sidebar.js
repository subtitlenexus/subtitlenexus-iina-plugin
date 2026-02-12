let currentApiKey = '';
let currentLogs = [];
let currentDomainWeb = '';

function formatCost(cost, costType) {
    if (cost == null || !costType) return null;
    const unit = costType === 'TOKEN'
        ? (cost === 1 ? 'token' : 'tokens')
        : (cost === 1 ? 'credit' : 'credits');
    return `${cost} ${unit}`;
}

function logToIINA(msg) {
    iina.postMessage('log', { message: msg });
}

function updateMainLangPreview() {
    const audioLang = document.getElementById('currentAudioLang').textContent || '--';
    const subtitleLang = document.getElementById('currentLang').textContent || '--';
    document.getElementById('mainLang').textContent = audioLang + ' → ' + subtitleLang;
}

function showMainView() {
    document.getElementById('mainView').classList.add('active');
    document.getElementById('languageView').classList.remove('active');
    document.getElementById('modelView').classList.remove('active');
    document.getElementById('apiView').classList.remove('active');
    document.getElementById('usageView').classList.remove('active');
    document.getElementById('advancedView').classList.remove('active');

    document.getElementById('status').textContent = '';
    document.getElementById('audioLangStatus').textContent = '';
    document.getElementById('modelStatus').textContent = '';
    document.getElementById('apiStatus').textContent = '';
}

function hideAllViews() {
    document.getElementById('mainView').classList.remove('active');
    document.getElementById('languageView').classList.remove('active');
    document.getElementById('modelView').classList.remove('active');
    document.getElementById('apiView').classList.remove('active');
    document.getElementById('usageView').classList.remove('active');
    document.getElementById('advancedView').classList.remove('active');
}

function showLanguageView() {
    hideAllViews();
    document.getElementById('languageView').classList.add('active');
    document.getElementById('status').textContent = '';
    document.getElementById('audioLangStatus').textContent = '';
}

function showModelView() {
    hideAllViews();
    document.getElementById('modelView').classList.add('active');
    document.getElementById('modelStatus').textContent = '';
}

function showApiView() {
    hideAllViews();
    document.getElementById('apiView').classList.add('active');
    document.getElementById('apiStatus').textContent = '';
}

function showUsageView() {
    hideAllViews();
    document.getElementById('usageView').classList.add('active');
    iina.postMessage('fetch-usage', {});
}

function updateUsageUI(state) {
    if (!state) return;
    document.getElementById('usageTokens').textContent = state.user_tokens != null ? state.user_tokens : '--';
    document.getElementById('usageSubtitleCredits').textContent = state.user_subtitle_credits != null ? state.user_subtitle_credits : '--';
    const betaRow = document.getElementById('usageBetaRow');
    if (state.user_beta_credits && state.user_beta_credits > 0) {
        betaRow.style.display = 'flex';
        document.getElementById('usageBetaCredits').textContent = state.user_beta_credits;
    } else {
        betaRow.style.display = 'none';
    }
}

function showAdvancedView() {
    hideAllViews();
    document.getElementById('advancedView').classList.add('active');
}

function updateCurrentApiKey(apiKey) {
    currentApiKey = apiKey;
    const display = document.getElementById('currentApiKey');

    if (!apiKey || apiKey === '') {
        display.textContent = 'Not Set';
        display.style.color = '#ff453a';
    } else {
        display.textContent = maskApiKey(apiKey);
        display.style.color = '#fff';
    }
}

function saveAudioLanguage() {
    const select = document.getElementById('audioLanguageSelect');
    const status = document.getElementById('audioLangStatus');
    const selectedLang = select.value;

    if (!selectedLang) return;

    try {
        iina.postMessage('set-audio-language', { language: selectedLang });
        const langName = select.options[select.selectedIndex].text;
        document.getElementById('currentAudioLang').textContent = langName;
        updateMainLangPreview();
        status.textContent = '✓ Audio language saved';

        setTimeout(() => { status.textContent = ''; }, 2000);
    } catch (e) {
        status.textContent = '✗ Error: ' + e.message;
        status.style.color = 'red';
    }
}

function saveSubtitleLanguage() {
    const select = document.getElementById('languageSelect');
    const status = document.getElementById('status');
    const selectedLang = select.value;

    if (!selectedLang) return;

    try {
        iina.postMessage('set-subtitle-language', { language: selectedLang });
        const langName = select.options[select.selectedIndex].text;
        document.getElementById('currentLang').textContent = langName;
        updateMainLangPreview();
        status.textContent = '✓ Subtitle language saved';

        setTimeout(() => { status.textContent = ''; }, 2000);
    } catch (e) {
        status.textContent = '✗ Error: ' + e.message;
        status.style.color = 'red';
    }
}

function saveModel() {
    const select = document.getElementById('modelSelect');
    const status = document.getElementById('modelStatus');
    const selectedModel = select.value;

    if (!selectedModel) return;

    try {
        iina.postMessage('set-model', { model: selectedModel });
        const modelName = select.options[select.selectedIndex].text;
        document.getElementById('currentModel').textContent = modelName;
        status.textContent = '✓ Model saved';

        setTimeout(() => { status.textContent = ''; }, 2000);
    } catch (e) {
        status.textContent = '✗ Error: ' + e.message;
        status.style.color = 'red';
    }
}

function maskApiKey(key) {
    if (key.length <= 11) return key;
    const first = key.substring(0, 8);
    const last = key.substring(key.length - 3);
    return `${first}...${last}`;
}

function saveApiKey() {
    const input = document.getElementById('apiKeyInput');
    const apiStatus = document.getElementById('apiStatus');
    const apiKey = input.value.trim();

    if (!apiKey) {
        apiStatus.textContent = '✗ API key cannot be empty';
        apiStatus.style.color = '#ff453a';
        return;
    }

    try {
        iina.postMessage('set-api-key', { api_key: apiKey });
        updateCurrentApiKey(apiKey);
        input.value = '';
        apiStatus.textContent = '✓ API key saved';
        apiStatus.style.color = '#30d158';

        setTimeout(() => { apiStatus.textContent = ''; }, 2000);
    } catch (e) {
        apiStatus.textContent = '✗ Error: ' + e.message;
        apiStatus.style.color = '#ff453a';
    }
}

function setButtonLoading(isLoading) {
    const btn = document.getElementById("transcription-btn");
    if (!btn) return;

    if (isLoading) {
        btn.disabled = true;
        btn.dataset.loading = "true";
        btn.textContent = "Starting...";
        btn.style.opacity = "0.6";
    } else {
        btn.disabled = false;
        btn.dataset.loading = "false";
        btn.style.opacity = "1";
    }
}

function toggleTranscription() {
    const btn = document.getElementById("transcription-btn");
    const action = btn && btn.dataset.action;

    if (btn.disabled) return;

    try {
        if (action === "processing" || action === "completed") {
            iina.postMessage('open-subtitle-url', {});
        } else if (action === "start") {
            setButtonLoading(true);
            iina.postMessage('start-transcription', {});
        }
    } catch (e) {
        setButtonLoading(false);
        alert('Error: ' + e.message);
    }
}

function cancelTranscription() {
    iina.postMessage('stop-transcription', {});
}

function updateStatusBadge(status) {
    const badge = document.getElementById('statusBadge');
    badge.classList.remove('not-submitted', 'processing', 'completed', 'demo');
    badge.classList.add(status);
    const labels = {
        'not-submitted': 'Not Submitted',
        'processing': 'Processing',
        'completed': 'Completed',
        'demo': 'Demo'
    };
    badge.querySelector('span').textContent = labels[status] || status;
}

function saveAutoTranscribe() {
    const checkbox = document.getElementById('autoTranscribe');
    logToIINA("[FE] Auto transcribe: " + checkbox.checked);
    iina.postMessage('set-auto-transcribe', { enabled: checkbox.checked });
}

function saveAutoPurchase() {
    const checkbox = document.getElementById('autoPurchase');
    logToIINA("[FE] Auto purchase: " + checkbox.checked);
    iina.postMessage('set-auto-purchase', { enabled: checkbox.checked });
}

function saveIgnoreCommunity() {
    const checkbox = document.getElementById('ignoreCommunity');
    logToIINA("[FE] Ignore community: " + checkbox.checked);
    iina.postMessage('set-ignore-community', { enabled: checkbox.checked });
}

function saveContributeThumbnails() {
    const checkbox = document.getElementById('contributeThumbnails');
    logToIINA("[FE] Contribute thumbnails: " + checkbox.checked);
    iina.postMessage('set-contribute-thumbnails', { enabled: checkbox.checked });
}

function saveSubtitleVisibility() {
    const select = document.getElementById('subtitleVisibility');
    logToIINA("[FE] Subtitle visibility: " + select.value);
    iina.postMessage('set-subtitle-visibility', { visibility: select.value });
}

function saveAudioFormat() {
    const select = document.getElementById('audioFormat');
    logToIINA("[FE] Audio format: " + select.value);
    iina.postMessage('set-audio-format', { format: select.value });
}

function openWorkDir() {
    iina.postMessage('open-work-dir', {});
}

function openConfigFile() {
    iina.postMessage('open-config-file', {});
}

function openWebsite() {
    iina.postMessage('open-url', { url: 'https://subtitlenexus.com/ai/subtitle-requests/' });
}

function openTopUp(path) {
    iina.postMessage('open-url', { url: 'https://' + currentDomainWeb + path });
}

function searchSubtitles() {
    iina.postMessage('search-subtitles');
}

function openPremiumPage() {
    iina.postMessage('open-premium-page');
}

function resetState() {
    iina.postMessage('reset-state', {});
}

function openLogsDir() {
    iina.postMessage('open-logs-dir', {});
}

function openLogsFile() {
    iina.postMessage('open-logs-file', {});
}

function startLogin() {
    logToIINA("[FE] Starting device login");
    iina.postMessage('start-device-login', {});
}

function doLogout() {
    logToIINA("[FE] Logging out");
    iina.postMessage('logout', {});
}

function retryConnection() {
    logToIINA("[FE] Retrying connection");
    const msgEl = document.getElementById('backendDownMessage');
    if (msgEl) msgEl.textContent = "Retrying connection...";
    iina.postMessage('retry-connection', {});
}

function updateAccountUI(state) {
    const loggedOutSection = document.getElementById('loggedOutSection');
    const loggedInSection = document.getElementById('loggedInSection');
    const mainBackendDown = document.getElementById('mainBackendDown');
    const mainLoggedOut = document.getElementById('mainLoggedOut');
    const mainLoggedIn = document.getElementById('mainLoggedIn');
    const userNameEl = document.getElementById('currentUserName');
    const mainAccountStatus = document.getElementById('mainAccountStatus');

    const apiHealthy = state && state.api_healthy;
    const apiKeyValid = state && state.api_key_valid;
    const userName = state && state.user_name;

    if (apiHealthy === false) {
        if (mainBackendDown) mainBackendDown.style.display = 'block';
        if (mainLoggedOut) mainLoggedOut.style.display = 'none';
        if (mainLoggedIn) mainLoggedIn.style.display = 'none';
        if (loggedOutSection) loggedOutSection.style.display = 'none';
        if (loggedInSection) loggedInSection.style.display = 'none';
        const msgEl = document.getElementById('backendDownMessage');
        const internetOk = state && state.internet_ok;
        if (msgEl) {
            if (internetOk === true) {
                msgEl.textContent = "Subtitle Nexus is down. Check subtitlenexus.com";
            } else if (internetOk === false) {
                msgEl.textContent = "No internet connection";
            } else {
                msgEl.textContent = "Unable to connect to Subtitle Nexus";
            }
        }
        return;
    }

    if (mainBackendDown) mainBackendDown.style.display = 'none';

    if (apiKeyValid) {
        if (loggedOutSection) loggedOutSection.style.display = 'none';
        if (loggedInSection) loggedInSection.style.display = 'block';
        if (mainLoggedOut) mainLoggedOut.style.display = 'none';
        if (mainLoggedIn) mainLoggedIn.style.display = 'block';
        if (userNameEl) userNameEl.textContent = userName || 'User';
        if (mainAccountStatus) mainAccountStatus.textContent = userName || 'Logged in';
    } else {
        if (loggedOutSection) loggedOutSection.style.display = 'block';
        if (loggedInSection) loggedInSection.style.display = 'none';
        if (mainLoggedOut) mainLoggedOut.style.display = 'block';
        if (mainLoggedIn) mainLoggedIn.style.display = 'none';
        if (mainAccountStatus) mainAccountStatus.textContent = 'Not logged in';
    }
}

window.addEventListener('DOMContentLoaded', () => {
    logToIINA("[FE] DOM loaded, initializing...");

    const transcriptionBtn = document.getElementById("transcription-btn");

    iina.onMessage("state-loaded", (state) => {
        logToIINA("[FE] Received state-loaded: " + JSON.stringify(state));

        updateAccountUI(state);
        updateUsageUI(state);

        if (transcriptionBtn) {
            setButtonLoading(false);

            const isActive = state && state.is_active;
            const phase = state && state.phase;
            const progress = state && state.progress;
            const uploadMb = state && state.upload_size_mb;
            const extractionPct = state && state.extraction_pct;
            const isProcessing = state && state.subtitle_id && state.subtitle_status !== "COMPLETED";
            const isCompleted = state && state.subtitle_status === "COMPLETED";
            const isDemo = state && state.is_demo;

            transcriptionBtn.dataset.active = isActive ? "true" : "false";

            if (isCompleted) {
                updateStatusBadge(isDemo ? 'demo' : 'completed');
            } else if (isActive || isProcessing) {
                updateStatusBadge('processing');
            } else {
                updateStatusBadge('not-submitted');
            }

            const cancelBtn = document.getElementById("cancel-btn");
            const showCancel = isActive && (phase === "extracting" || phase === "uploading");
            if (cancelBtn) cancelBtn.style.display = showCancel ? "block" : "none";

            const isIdle = !isActive && !isProcessing && !isCompleted;
            const searchBtn = document.getElementById("search-btn");
            if (searchBtn) searchBtn.style.display = isIdle ? "block" : "none";

            if (isActive && phase === "extracting") {
                const pct = extractionPct && extractionPct > 0 ? ` (${extractionPct}%)` : "";
                transcriptionBtn.textContent = `Extracting Audio${pct}`;
                transcriptionBtn.disabled = true;
                transcriptionBtn.style.border = "2px solid #ff9f0a";
                transcriptionBtn.dataset.action = "none";
            } else if (isActive && phase === "uploading") {
                const mb = uploadMb ? uploadMb.toFixed(1) : "?";
                transcriptionBtn.textContent = `Uploading (${mb} MB)`;
                transcriptionBtn.disabled = true;
                transcriptionBtn.style.border = "2px solid #ff9f0a";
                transcriptionBtn.dataset.action = "none";
            } else if (isProcessing) {
                const pct = progress && progress > 0 ? ` (${progress}%)` : "";
                transcriptionBtn.textContent = `View Subtitles${pct} ↗`;
                transcriptionBtn.disabled = false;
                transcriptionBtn.style.border = "2px solid #30d158";
                transcriptionBtn.dataset.action = "processing";
            } else if (isCompleted) {
                transcriptionBtn.textContent = isDemo ? "View Demo Subtitles ↗" : "View Subtitles ↗";
                transcriptionBtn.disabled = false;
                transcriptionBtn.style.border = "";
                transcriptionBtn.dataset.action = "completed";
            } else {
                if (state.can_purchase === false) {
                    transcriptionBtn.textContent = "Start Live Subtitles";
                    transcriptionBtn.disabled = true;
                    transcriptionBtn.style.border = "";
                    transcriptionBtn.style.opacity = "0.5";
                    transcriptionBtn.dataset.action = "none";
                } else {
                    transcriptionBtn.textContent = "Start Live Subtitles";
                    transcriptionBtn.disabled = false;
                    transcriptionBtn.style.border = "";
                    transcriptionBtn.style.opacity = "1";
                    transcriptionBtn.dataset.action = "start";
                }
            }

            const helperText = document.querySelector('.helper-text');
            if (helperText && !isIdle) {
                helperText.style.display = 'none';
            } else if (helperText) {
                helperText.style.display = 'block';
                if (state.can_purchase === false) {
                    const path = state.user_plan === 'free' ? '/products/pricing/' : '/products/tokens/';
                    helperText.innerHTML = 'Insufficient balance \u2014 <a href="#" onclick="openTopUp(\'' + path + '\'); return false;" style="color: #30d158;">Top up \u2197</a>';
                } else {
                    const costLabel = formatCost(state.current_cost, state.cost_type);
                    const base = "Subtitles stream as you watch \u2014 first line appears in ~90s";
                    helperText.textContent = costLabel ? costLabel + " \u00b7 " + base : base;
                }
            }
        }

        const lastErrorDiv = document.getElementById('lastError');
        logToIINA("[FE] state.last_error: " + (state && state.last_error));
        if (state && state.last_error) {
            lastErrorDiv.textContent = "Last Error: " + state.last_error;
            lastErrorDiv.style.display = "block";
        } else {
            lastErrorDiv.style.display = "none";
        }

        if (state && state.logs) {
            currentLogs = state.logs;
            const preview = document.getElementById('logsPreview');
            if (preview) preview.textContent = state.logs.slice(-10).join('\n') || '(no logs)';
        }

        if (state && state.audio_language) {
            const audioLangSelect = document.getElementById('audioLanguageSelect');
            audioLangSelect.value = state.audio_language;
            const audioLangOption = audioLangSelect.options[audioLangSelect.selectedIndex];
            const audioLangName = audioLangOption ? audioLangOption.text : state.audio_language;
            document.getElementById('currentAudioLang').textContent = audioLangName;
            updateMainLangPreview();
        }

        const getPremiumBtn = document.getElementById('getPremiumBtn');
        const premiumBadge = document.getElementById('premiumBadge');
        if (state && state.user_plan) {
            const isFree = state.user_plan === "free";
            if (getPremiumBtn) getPremiumBtn.style.display = isFree ? "block" : "none";
            if (premiumBadge) premiumBadge.style.display = isFree ? "none" : "inline";
        }
        const modelSelect = document.getElementById('modelSelect');
        const isBeta = state && state.is_beta_user;
        const betaModels = [{ value: "lulu-preview-2601", text: "lulu-preview-2601" }];
        betaModels.forEach(m => {
            const existing = modelSelect.querySelector(`option[value="${m.value}"]`);
            if (isBeta && !existing) {
                const opt = document.createElement('option');
                opt.value = m.value; opt.textContent = m.text; opt.className = 'beta-option';
                modelSelect.appendChild(opt);
            } else if (!isBeta && existing) {
                existing.remove();
            }
        });
    });

    iina.onMessage("config-loaded", (config) => {
        logToIINA("[FE] Config loaded: " + JSON.stringify(config));

        if (config.domain_web) currentDomainWeb = config.domain_web;

        if (config.subtitle_language_code) {
            const langSelect = document.getElementById('languageSelect');
            langSelect.value = config.subtitle_language_code;
            const langOption = langSelect.options[langSelect.selectedIndex];
            const langName = langOption ? langOption.text : config.subtitle_language_code;
            document.getElementById('currentLang').textContent = langName;
            updateMainLangPreview();
        }

        if (config.model) {
            document.getElementById('currentModel').textContent = config.model;
            document.getElementById('modelSelect').value = config.model;
            document.getElementById('mainModel').textContent = config.model;
        }

        if (config.api_key) {
            const masked = maskApiKey(config.api_key);
            const currentApiKeyEl = document.getElementById('currentApiKey');
            const currentApiKeyLoggedInEl = document.getElementById('currentApiKeyLoggedIn');
            if (currentApiKeyEl) currentApiKeyEl.textContent = masked;
            if (currentApiKeyLoggedInEl) currentApiKeyLoggedInEl.textContent = masked;
        }

        const checkbox = document.getElementById('autoTranscribe');
        if (checkbox) {
            checkbox.checked = config.auto_transcribe_new_files === true;
        }

        const autoPurchaseCheckbox = document.getElementById('autoPurchase');
        if (autoPurchaseCheckbox) {
            autoPurchaseCheckbox.checked = config.auto_purchase_past_daily_limit === true;
        }

        const ignoreCommunityCheckbox = document.getElementById('ignoreCommunity');
        if (ignoreCommunityCheckbox) {
            ignoreCommunityCheckbox.checked = config.ignore_community_subs === true;
        }

        const contributeThumbnailsCheckbox = document.getElementById('contributeThumbnails');
        if (contributeThumbnailsCheckbox) {
            contributeThumbnailsCheckbox.checked = config.contribute_thumbnails !== false;
        }

        const subtitleVisibilitySelect = document.getElementById('subtitleVisibility');
        if (subtitleVisibilitySelect && config.subtitle_visibility) {
            subtitleVisibilitySelect.value = config.subtitle_visibility;
        }

        const audioFormatSelect = document.getElementById('audioFormat');
        if (audioFormatSelect && config.audio_format) {
            audioFormatSelect.value = config.audio_format;
        }
    });

    iina.postMessage("sidebar-ready", {});
    logToIINA("[FE] Sidebar ready");

    setInterval(() => {
        iina.postMessage("poll-state", {});
    }, 3000);
});
