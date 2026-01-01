const { mpv, console: log, sidebar, event, utils, core, file } = iina;
log.log("Nexus Controls plugin loaded!");

log.log("====================")
log.log("====================")
log.log("====================")
log.log("====================")
log.log("====================")
log.log("====================")

const IINA_PLUGINS_DIR = '~/Library/Application Support/com.colliderli.iina/plugins/';
const PLUGIN_NAME = 'iina-nexus-plugin.iinaplugin';
const PLUGIN_NAME_DEV = 'iina-nexus-plugin.iinaplugin-dev';
const NEXUS_SCRIPTS = ["language.lua", "nexus-utils.lua", "srt-parser.lua", "nexus.lua"];

function getPluginPath() {
    if (utils.fileInPath(IINA_PLUGINS_DIR + PLUGIN_NAME)) {
        return utils.resolvePath(IINA_PLUGINS_DIR + PLUGIN_NAME);
    } else if (utils.fileInPath(IINA_PLUGINS_DIR + PLUGIN_NAME_DEV)) {
        return utils.resolvePath(IINA_PLUGINS_DIR + PLUGIN_NAME_DEV);
    } else {
        throw new Error("Unable to locate plugin folder.");
    }
}


function getPluginDataPath() {
    return utils.resolvePath("@data/")
}

let sidebarReady = false;

function syncToSidebar(delay = 100) {
    setTimeout(() => {
        const state = mpv.getNative("user-data/nexus/state");
        const config = mpv.getNative("user-data/nexus/config");
        if (state) sidebar.postMessage("state-loaded", state);
        if (config) sidebar.postMessage("config-loaded", config);
    }, delay);
}

mpv.set("user-data/nexus/is_iina", true);

NEXUS_SCRIPTS.forEach(script => {
    const pluginPath = getPluginPath();
    const scriptPath = `${pluginPath}/mpv/scripts/${script}`;
    log.log("Loading script: " + scriptPath);
    try {
        mpv.command("load-script", [scriptPath]);
        log.log("✓ Loaded " + script);
    } catch (e) {
        log.log("✗ Error loading " + script + ": " + e);
    }
});

event.on("iina.window-loaded", () => {
    log.log("Window loaded! Loading sidebar...");
    sidebar.loadFile("src/sidebar.html");

    sidebar.onMessage("log", (data) => {
        log.log("[sidebar] " + data.message);
    });

    sidebar.onMessage("sidebar-ready", () => {
        log.log("Sidebar ready");
        sidebarReady = true;
        syncToSidebar();
    });

    sidebar.onMessage("start-transcription", () => {
        if (!core.status.url) {
            log.log("ERROR: No file loaded, cannot start transcription");
            return;
        }
        log.log("Starting transcription...");
        mpv.command('script-message', ['start-ai-transcription']);
        syncToSidebar(5000);
    });

    sidebar.onMessage("set-audio-language", (data) => {
        log.log("✓ Set audio language: " + data.language);
        mpv.command('script-message', ['set-audio-language', data.language]);
    });

    sidebar.onMessage("set-subtitle-language", (data) => {
        log.log("✓ Set subtitle language: " + data.language);
        mpv.command('script-message', ['set-config-subtitle-language', data.language]);
    });

    sidebar.onMessage("set-model", (data) => {
        log.log("✓ Set model request received: " + data.model);
        mpv.command('script-message', ['set-config-model', data.model]);
    });

    sidebar.onMessage("set-api-key", (data) => {
        log.log("✓ Set API key: " + data.api_key.substring(0, 8) + "...");
        mpv.command('script-message', ['set-config-api-key', data.api_key]);
    });

    sidebar.onMessage("set-auto-transcribe", (data) => {
        log.log("✓ Set auto-transcribe: " + data.enabled);
        mpv.command('script-message', ['set-config-auto-transcribe', data.enabled ? "true" : "false"]);
    });

    sidebar.onMessage("set-auto-purchase", (data) => {
        log.log("✓ Set auto-purchase: " + data.enabled);
        mpv.command('script-message', ['set-config-auto-purchase', data.enabled ? "true" : "false"]);
    });

    sidebar.onMessage("set-ignore-community", (data) => {
        log.log("✓ Set ignore-community: " + data.enabled);
        mpv.command('script-message', ['set-config-ignore-community', data.enabled ? "true" : "false"]);
    });

    sidebar.onMessage("set-audio-format", (data) => {
        log.log("✓ Set audio-format: " + data.format);
        mpv.command('script-message', ['set-config-audio-format', data.format]);
    });

    sidebar.onMessage("open-subtitle-url", () => {
        log.log("✓ Open subtitle URL");
        mpv.command('script-message', ['open-subtitle-url']);
    });

    sidebar.onMessage("poll-state", () => {
        const state = mpv.getNative("user-data/nexus/state");
        const config = mpv.getNative("user-data/nexus/config");
        if (state) sidebar.postMessage("state-loaded", state);
        if (config) sidebar.postMessage("config-loaded", config);
    });

    sidebar.onMessage("open-work-dir", () => {
        log.log("✓ Open work dir");
        mpv.command('script-message', ['open-work-dir']);
    });

    sidebar.onMessage("open-config-file", () => {
        log.log("✓ Open config file");
        mpv.command('script-message', ['open-config-file']);
    });

    sidebar.onMessage("open-url", (data) => {
        log.log("✓ Open URL: " + data.url);
        mpv.command('script-message', ['open-url', data.url]);
    });

    sidebar.onMessage("reset-state", () => {
        log.log("✓ Reset state");
        mpv.command('script-message', ['reset-state']);
    });

    sidebar.onMessage("export-logs", () => {
        mpv.command('script-message', ['export-logs']);
    });

    sidebar.onMessage("open-premium-page", () => {
        log.log("✓ Open premium page");
        mpv.command('script-message', ['open-premium-page']);
    });

    sidebar.onMessage("start-device-login", () => {
        log.log("✓ Start device login");
        mpv.command('script-message', ['start-device-login']);
        let attempts = 0;
        const pollForCode = setInterval(() => {
            const state = mpv.getNative("user-data/nexus/state");
            if (state && state.pending_device_code) {
                clearInterval(pollForCode);
                utils.ask("Device Code: " + state.pending_device_code);
                syncToSidebar(100);
            } else if (++attempts > 20) {
                clearInterval(pollForCode);
                log.log("✗ Timeout waiting for device code");
            }
        }, 250);
    });

    sidebar.onMessage("logout", () => {
        log.log("✓ Logout");
        mpv.command('script-message', ['logout']);
        syncToSidebar(100);
    });
});

function onFileOrWindowLoaded() {
    const base_dir = getPluginDataPath();
    mpv.command('script-message', ['init-state', base_dir]);
    if (sidebarReady) {
        syncToSidebar(100);
    }
}

event.on("iina.file-loaded", onFileOrWindowLoaded);
event.on("iina.window-loaded", onFileOrWindowLoaded);
