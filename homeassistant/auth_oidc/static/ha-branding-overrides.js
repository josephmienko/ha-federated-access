/**
 * Built file for the HA Branding Overrides HACS artifact.
 * Edit src/ha-branding-overrides.js and rerun npm run build.
 */

const OBSERVED_ROOTS = new WeakSet();
const SHADOW_PATCH_KEY = "__haBrandingOverridesShadowPatch";
const AUTH_THEME_STYLE_ID = "ha-branding-overrides-auth-theme";

let scheduledFrame = null;

const DEFAULT_AUTH_THEME = {
  light: {
    primary: "#6D9B7B",
    onPrimary: "#FFFFFF",
    surface: "#FFF9EE",
    onSurface: "#1E1B13",
    surfaceContainer: "#F4EDDF",
    surfaceContainerHigh: "#EEE8DA",
    onSurfaceVariant: "#4B4739",
    outline: "#CDC6B4",
    accent: "#FFDE3F",
  },
  dark: {
    primary: "#6D9B7B",
    onPrimary: "#FFFFFF",
    surface: "#15130B",
    onSurface: "#E8E2D4",
    surfaceContainer: "#222017",
    surfaceContainerHigh: "#2D2A21",
    onSurfaceVariant: "#CDC6B4",
    outline: "#4B4739",
    accent: "#FFDE3F",
  },
};

function normalizeText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function firstString(values, fallback = "") {
  for (const value of values) {
    if (typeof value !== "string") {
      continue;
    }
    const trimmed = value.trim();
    if (trimmed) {
      return trimmed;
    }
  }
  return fallback;
}

function normalizeStringList(items) {
  const source = Array.isArray(items) ? items : [];
  return [...new Set(source.filter((value) => typeof value === "string").map((value) => value.trim()).filter(Boolean))];
}

function normalizeReplacements(items, defaults = []) {
  const source = Array.isArray(items) ? items : defaults;
  return source
    .map((item) => {
      if (!item || typeof item !== "object") {
        return null;
      }

      const from = firstString([item.from], "");
      const to = firstString([item.to], "");
      return from && to ? { from, to } : null;
    })
    .filter(Boolean);
}

function normalizeThemeMode(raw, fallback) {
  const input = raw && typeof raw === "object" ? raw : {};
  return {
    primary: firstString([input.primary], fallback.primary),
    onPrimary: firstString([input.onPrimary, input.on_primary], fallback.onPrimary),
    surface: firstString([input.surface], fallback.surface),
    onSurface: firstString([input.onSurface, input.on_surface], fallback.onSurface),
    surfaceContainer: firstString(
      [input.surfaceContainer, input.surface_container],
      fallback.surfaceContainer
    ),
    surfaceContainerHigh: firstString(
      [input.surfaceContainerHigh, input.surface_container_high],
      fallback.surfaceContainerHigh
    ),
    onSurfaceVariant: firstString(
      [input.onSurfaceVariant, input.on_surface_variant],
      fallback.onSurfaceVariant
    ),
    outline: firstString([input.outline], fallback.outline),
    accent: firstString([input.accent], fallback.accent),
  };
}

function normalizeAuthConfig(input, base) {
  const legacyAuth =
    window.auth_oidc_branding && typeof window.auth_oidc_branding === "object"
      ? window.auth_oidc_branding
      : {};
  const rawAuth = input.auth && typeof input.auth === "object" ? input.auth : {};
  const authInput = { ...legacyAuth, ...rawAuth };
  const hasAuthInput = Object.keys(authInput).length > 0;
  const enabled = authInput.enabled !== false && (authInput.enabled === true || hasAuthInput);
  const icons = authInput.icons && typeof authInput.icons === "object" ? authInput.icons : {};
  const logos = authInput.logos && typeof authInput.logos === "object" ? authInput.logos : {};
  const theme = authInput.theme && typeof authInput.theme === "object" ? authInput.theme : {};
  const name = firstString(
    [
      authInput.name,
      authInput.appName,
      authInput.app_name,
      authInput.brandName,
      authInput.brand_name,
      base.appName,
    ],
    ""
  );
  const icon32Url = firstString(
    [
      authInput.icon32Url,
      authInput.icon32_url,
      authInput.icon32,
      authInput.icon_32_url,
      authInput.favicon32,
      authInput.favicon_32,
      icons.icon32Url,
      icons.icon32_url,
      icons.icon32,
      icons.icon_32_url,
      icons.favicon32,
      icons.favicon_32,
      base.icon32Url,
    ],
    ""
  );
  const icon192Url = firstString(
    [
      authInput.icon192Url,
      authInput.icon192_url,
      authInput.icon192,
      authInput.icon_192_url,
      authInput.favicon192,
      authInput.favicon_192,
      icons.icon192Url,
      icons.icon192_url,
      icons.icon192,
      icons.icon_192_url,
      icons.favicon192,
      icons.favicon_192,
      base.icon192Url,
    ],
    ""
  );
  const logoUrl = firstString(
    [
      authInput.logoUrl,
      authInput.logo_url,
      authInput.logo,
      icons.logoUrl,
      icons.logo_url,
      icons.logo,
      base.logoUrl,
      icon192Url,
      icon32Url,
    ],
    ""
  );
  const logoLightUrl = firstString(
    [
      authInput.logoLightUrl,
      authInput.logo_light_url,
      authInput.logoLight,
      authInput.logo_light,
      authInput.lightLogoUrl,
      authInput.light_logo_url,
      authInput.lightLogo,
      authInput.light_logo,
      logos.lightUrl,
      logos.light_url,
      logos.light,
      logoUrl,
    ],
    logoUrl
  );
  const logoDarkUrl = firstString(
    [
      authInput.logoDarkUrl,
      authInput.logo_dark_url,
      authInput.logoDark,
      authInput.logo_dark,
      authInput.darkLogoUrl,
      authInput.dark_logo_url,
      authInput.darkLogo,
      authInput.dark_logo,
      logos.darkUrl,
      logos.dark_url,
      logos.dark,
      logoUrl,
    ],
    logoUrl
  );
  const primaryColor = firstString([authInput.themeColor, authInput.theme_color, base.themeColor], "");
  const lightFallback = { ...DEFAULT_AUTH_THEME.light };
  const darkFallback = { ...DEFAULT_AUTH_THEME.dark };
  if (primaryColor) {
    lightFallback.primary = primaryColor;
    darkFallback.primary = primaryColor;
  }

  return {
    enabled,
    name,
    icon32Url,
    icon192Url,
    logoUrl,
    logoLightUrl,
    logoDarkUrl,
    logoAlt: firstString([authInput.logoAlt, authInput.logo_alt, name, base.logoAlt], ""),
    logoSelectors: normalizeStringList(authInput.logoSelectors).length
      ? normalizeStringList(authInput.logoSelectors)
      : [".header img"],
    theme: {
      light: normalizeThemeMode(theme.light, lightFallback),
      dark: normalizeThemeMode(theme.dark, darkFallback),
    },
  };
}

function normalizeConfig(raw) {
  const input = raw && typeof raw === "object" ? raw : {};
  const homeAssistantName = firstString(
    [input.homeAssistantName, input.home_assistant_name],
    "Home Assistant"
  );
  const appName = firstString([input.appName, input.brandName, input.brand_name, input.name], "");
  const defaultReplacement = appName ? [{ from: homeAssistantName, to: appName }] : [];
  const icon32Url = firstString(
    [input.icon32Url, input.icon32_url, input.favicon32, input.favicon_32],
    ""
  );
  const icon192Url = firstString(
    [input.icon192Url, input.icon192_url, input.favicon192, input.favicon_192, input.iconUrl, input.icon_url],
    ""
  );
  const base = {
    appName,
    homeAssistantName,
    icon32Url,
    icon192Url,
    logoUrl: firstString([input.logoUrl, input.logo_url, input.logo], ""),
    logoAlt: firstString([input.logoAlt, input.logo_alt], ""),
    themeColor: firstString([input.themeColor, input.theme_color], ""),
  };

  return {
    appName,
    homeAssistantName,
    icon32Url,
    icon192Url,
    logoUrl: base.logoUrl,
    logoAlt: base.logoAlt,
    logoSelectors: normalizeStringList(input.logoSelectors),
    removeSelectors: normalizeStringList(input.removeSelectors),
    themeColor: base.themeColor,
    titleReplacements: normalizeReplacements(input.titleReplacements, defaultReplacement),
    textReplacements: normalizeReplacements(input.textReplacements, defaultReplacement),
    auth: normalizeAuthConfig(input, base),
  };
}

const BRANDING = normalizeConfig(window.ha_branding_overrides);

function hasBrandingWork() {
  return Boolean(
    BRANDING.appName ||
      BRANDING.icon32Url ||
      BRANDING.icon192Url ||
      BRANDING.logoUrl ||
      BRANDING.logoSelectors.length ||
      BRANDING.removeSelectors.length ||
      BRANDING.themeColor ||
      BRANDING.titleReplacements.length ||
      BRANDING.textReplacements.length ||
      BRANDING.auth.enabled
  );
}

function iconTypeForHref(href) {
  const normalized = normalizeText(href).toLowerCase();
  if (normalized.includes(".svg")) {
    return "image/svg+xml";
  }
  if (normalized.includes(".png")) {
    return "image/png";
  }
  if (normalized.includes(".ico")) {
    return "image/x-icon";
  }
  return "";
}

function ensureHeadLink(id, rel, href) {
  if (!href) {
    return;
  }

  let link = document.getElementById(id);
  if (!(link instanceof HTMLLinkElement)) {
    link = document.createElement("link");
    link.id = id;
    document.head.appendChild(link);
  }

  if (link.rel !== rel) {
    link.rel = rel;
  }
  if (link.href !== href) {
    link.href = href;
  }

  const iconType = iconTypeForHref(href);
  if (iconType && link.type !== iconType) {
    link.type = iconType;
  }
}

function updateExistingHeadIconLinks(href) {
  if (!href) {
    return;
  }

  const selectors = [
    'link[rel="icon"]',
    'link[rel~="icon"]',
    'link[rel="shortcut icon"]',
    'link[rel="apple-touch-icon"]',
  ];

  const links = document.head.querySelectorAll(selectors.join(","));
  const iconType = iconTypeForHref(href);
  links.forEach((node) => {
    if (!(node instanceof HTMLLinkElement)) {
      return;
    }

    if (node.href !== href) {
      node.href = href;
    }

    if (iconType && !node.rel.includes("apple-touch-icon") && node.type !== iconType) {
      node.type = iconType;
    }
  });
}

function ensureMeta(name, content) {
  if (!content) {
    return;
  }

  let meta = document.head.querySelector(`meta[name="${name}"]`);
  if (!(meta instanceof HTMLMetaElement)) {
    meta = document.createElement("meta");
    meta.name = name;
    document.head.appendChild(meta);
  }

  if (meta.content !== content) {
    meta.content = content;
  }
}

function applyReplacements(value, replacements) {
  let next = value;
  for (const replacement of replacements) {
    if (!next.includes(replacement.from)) {
      continue;
    }
    next = next.replaceAll(replacement.from, replacement.to);
  }
  return next;
}

function replaceExactText(target, sourceText, replacement) {
  if (!target) {
    return;
  }

  const normalizedSource = normalizeText(sourceText);
  if (!normalizedSource) {
    return;
  }

  const directTextNodes = Array.from(target.childNodes).filter(
    (node) => node.nodeType === Node.TEXT_NODE && normalizeText(node.textContent)
  );

  if (directTextNodes.length === 1 && normalizeText(directTextNodes[0].textContent) === normalizedSource) {
    directTextNodes[0].textContent = replacement;
    return;
  }

  if (target.childElementCount === 0 && normalizeText(target.textContent) === normalizedSource) {
    target.textContent = replacement;
  }
}

function replaceTextNodes(element) {
  if (!(element instanceof Element)) {
    return;
  }
  if (element.tagName === "SCRIPT" || element.tagName === "STYLE") {
    return;
  }

  for (const node of Array.from(element.childNodes)) {
    if (node.nodeType !== Node.TEXT_NODE || !node.textContent) {
      continue;
    }

    const next = applyReplacements(node.textContent, BRANDING.textReplacements);
    if (next !== node.textContent) {
      node.textContent = next;
    }
  }
}

function replaceAttributeText(element, attributeName) {
  const current = element.getAttribute(attributeName);
  if (current == null) {
    return;
  }

  let next = applyReplacements(current, BRANDING.textReplacements);
  if (BRANDING.appName && normalizeText(next) === BRANDING.homeAssistantName) {
    next = BRANDING.appName;
  }

  if (next !== current) {
    element.setAttribute(attributeName, next);
  }
}

function applyTitleBranding() {
  let next = document.title || "";
  if (BRANDING.appName && normalizeText(next) === BRANDING.homeAssistantName) {
    next = BRANDING.appName;
  }
  next = applyReplacements(next, BRANDING.titleReplacements);
  if (!next && BRANDING.appName) {
    next = BRANDING.appName;
  }
  if (next && document.title !== next) {
    document.title = next;
  }
}

function applyHeadBranding() {
  const primaryIconUrl = BRANDING.icon192Url || BRANDING.icon32Url;
  const smallIconUrl = BRANDING.icon32Url || BRANDING.icon192Url;

  updateExistingHeadIconLinks(primaryIconUrl || smallIconUrl);
  ensureHeadLink("ha-branding-overrides-favicon", "icon", smallIconUrl || primaryIconUrl);
  ensureHeadLink(
    "ha-branding-overrides-shortcut-icon",
    "shortcut icon",
    smallIconUrl || primaryIconUrl
  );
  ensureHeadLink(
    "ha-branding-overrides-apple-touch-icon",
    "apple-touch-icon",
    primaryIconUrl || smallIconUrl
  );
  ensureMeta("application-name", BRANDING.appName);
  ensureMeta("apple-mobile-web-app-title", BRANDING.appName);
  ensureMeta("theme-color", BRANDING.themeColor);
  applyTitleBranding();
}

function walkOpenRoots(root, visitElement, visitRoot, seen = new WeakSet()) {
  if (!root || seen.has(root)) {
    return;
  }
  seen.add(root);

  if (visitRoot && root.querySelectorAll) {
    visitRoot(root);
  }

  if (visitElement && root instanceof Element) {
    visitElement(root);
  }

  const elements = root.querySelectorAll ? root.querySelectorAll("*") : [];
  for (const element of elements) {
    if (visitElement) {
      visitElement(element);
    }
    if (element.shadowRoot) {
      walkOpenRoots(element.shadowRoot, visitElement, visitRoot, seen);
    }
  }
}

function applyRemoveSelectors() {
  if (!BRANDING.removeSelectors.length) {
    return;
  }

  const removed = new Set();
  walkOpenRoots(document, null, (root) => {
    for (const selector of BRANDING.removeSelectors) {
      root.querySelectorAll(selector).forEach((node) => {
        if (!(node instanceof Element) || removed.has(node)) {
          return;
        }
        removed.add(node);
        node.remove();
      });
    }
  });
}

function applyLogoBranding() {
  if (!BRANDING.logoUrl || !BRANDING.logoSelectors.length) {
    return;
  }

  const seen = new Set();
  const logoAlt = BRANDING.logoAlt || BRANDING.appName;

  walkOpenRoots(document, null, (root) => {
    for (const selector of BRANDING.logoSelectors) {
      root.querySelectorAll(selector).forEach((node) => {
        if (!(node instanceof HTMLImageElement) || seen.has(node)) {
          return;
        }
        seen.add(node);

        if (node.src !== BRANDING.logoUrl) {
          node.src = BRANDING.logoUrl;
        }
        if (logoAlt && node.alt !== logoAlt) {
          node.alt = logoAlt;
        }
      });
    }
  });
}

function prefersLightColorScheme() {
  return Boolean(window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches);
}

function isAuthPage() {
  const path = window.location?.pathname || "";
  if (path.startsWith("/auth/")) {
    return true;
  }

  return Boolean(
    document.querySelector("ha-authorize, ha-auth-flow, ha-auth-form, ha-pick-auth-provider")
  );
}

function activeAuthTheme() {
  return prefersLightColorScheme() ? BRANDING.auth.theme.light : BRANDING.auth.theme.dark;
}

function activeAuthLogoUrl() {
  const themedLogo = prefersLightColorScheme()
    ? BRANDING.auth.logoLightUrl
    : BRANDING.auth.logoDarkUrl;
  return firstString([themedLogo, BRANDING.auth.logoUrl], BRANDING.auth.logoUrl);
}

function applyAuthThemeVars(theme) {
  const targets = [
    document.documentElement,
    document.body,
    ...document.querySelectorAll("ha-authorize, ha-auth-flow, ha-auth-form"),
  ].filter(Boolean);
  const setVar = (name, value) => {
    targets.forEach((element) => element.style.setProperty(name, value, "important"));
  };

  setVar("--ha-branding-auth-primary", theme.primary);
  setVar("--ha-branding-auth-on-primary", theme.onPrimary);
  setVar("--ha-branding-auth-surface", theme.surface);
  setVar("--ha-branding-auth-on-surface", theme.onSurface);
  setVar("--ha-branding-auth-surface-container", theme.surfaceContainer);
  setVar("--ha-branding-auth-surface-container-high", theme.surfaceContainerHigh);
  setVar("--ha-branding-auth-on-surface-variant", theme.onSurfaceVariant);
  setVar("--ha-branding-auth-outline", theme.outline);
  setVar("--ha-branding-auth-accent", theme.accent);

  setVar("--primary-color", theme.primary);
  setVar("--accent-color", theme.accent);
  setVar("--mdc-theme-primary", theme.primary);
  setVar("--mdc-theme-secondary", theme.accent);
  setVar("--mdc-theme-on-primary", theme.onPrimary);
  setVar("--mdc-theme-surface", theme.surface);
  setVar("--mdc-theme-on-surface", theme.onSurface);
}

function ensureAuthThemeStyle() {
  if (document.getElementById(AUTH_THEME_STYLE_ID)) {
    return;
  }

  const style = document.createElement("style");
  style.id = AUTH_THEME_STYLE_ID;
  style.textContent = `
    :root {
      color-scheme: light dark;
    }

    body,
    ha-authorize {
      background: var(--ha-branding-auth-surface) !important;
      color: var(--ha-branding-auth-on-surface) !important;
    }

    ha-authorize .card-content {
      background: var(--ha-branding-auth-surface-container) !important;
      color: var(--ha-branding-auth-on-surface) !important;
      border: 1px solid var(--ha-branding-auth-outline) !important;
      border-radius: 28px !important;
      box-shadow: none !important;
    }

    ha-authorize .mdc-text-field,
    ha-authorize .mdc-text-field--filled,
    ha-authorize .mdc-text-field__input {
      background: var(--ha-branding-auth-surface-container-high) !important;
      color: var(--ha-branding-auth-on-surface) !important;
    }

    ha-authorize .mdc-floating-label,
    ha-authorize .mdc-text-field-helper-text,
    ha-authorize .mdc-text-field-helper-line,
    ha-authorize p,
    ha-authorize .or {
      color: var(--ha-branding-auth-on-surface-variant) !important;
    }

    ha-authorize .mdc-line-ripple::before,
    ha-authorize .mdc-line-ripple::after {
      border-bottom-color: var(--ha-branding-auth-primary) !important;
    }

    ha-authorize .forgot-password,
    ha-authorize a {
      color: var(--ha-branding-auth-primary) !important;
    }

    ha-authorize ha-button,
    ha-authorize mwc-button {
      --mdc-theme-primary: var(--ha-branding-auth-primary);
      --mdc-theme-on-primary: var(--ha-branding-auth-on-primary);
      --mdc-button-disabled-ink-color: var(--ha-branding-auth-on-surface-variant);
      border-radius: 999px !important;
      box-shadow: none !important;
    }

    ha-authorize ha-list-item {
      color: var(--ha-branding-auth-on-surface) !important;
    }
  `;
  document.head.appendChild(style);
}

function applyAuthHeadBranding(theme) {
  const primaryIconUrl = BRANDING.auth.icon192Url || BRANDING.auth.icon32Url;
  const smallIconUrl = BRANDING.auth.icon32Url || BRANDING.auth.icon192Url;

  if (BRANDING.auth.name && document.title !== BRANDING.auth.name) {
    document.title = BRANDING.auth.name;
  }

  updateExistingHeadIconLinks(primaryIconUrl || smallIconUrl);
  ensureHeadLink("ha-branding-overrides-auth-favicon", "icon", smallIconUrl || primaryIconUrl);
  ensureHeadLink(
    "ha-branding-overrides-auth-shortcut-icon",
    "shortcut icon",
    smallIconUrl || primaryIconUrl
  );
  ensureHeadLink(
    "ha-branding-overrides-auth-apple-touch-icon",
    "apple-touch-icon",
    primaryIconUrl || smallIconUrl
  );
  ensureMeta("application-name", BRANDING.auth.name);
  ensureMeta("apple-mobile-web-app-title", BRANDING.auth.name);
  ensureMeta("theme-color", theme.primary);
}

function applyAuthLogoBranding() {
  const logoUrl = activeAuthLogoUrl();
  if (!logoUrl || !BRANDING.auth.logoSelectors.length) {
    return;
  }

  const logoAlt = BRANDING.auth.logoAlt || BRANDING.auth.name;
  walkOpenRoots(document, null, (root) => {
    for (const selector of BRANDING.auth.logoSelectors) {
      root.querySelectorAll(selector).forEach((node) => {
        if (!(node instanceof HTMLImageElement)) {
          return;
        }

        if (node.getAttribute("src") !== logoUrl) {
          node.setAttribute("src", logoUrl);
        }
        if (logoAlt && node.alt !== logoAlt) {
          node.alt = logoAlt;
        }
      });
    }
  });
}

function applyAuthBranding() {
  if (!BRANDING.auth.enabled || !isAuthPage()) {
    return;
  }

  const theme = activeAuthTheme();
  applyAuthHeadBranding(theme);
  applyAuthThemeVars(theme);
  ensureAuthThemeStyle();
  applyAuthLogoBranding();
}

function applyTextBranding() {
  walkOpenRoots(document, (element) => {
    if (!(element instanceof Element)) {
      return;
    }

    replaceTextNodes(element);
    replaceAttributeText(element, "title");
    replaceAttributeText(element, "aria-label");

    if (BRANDING.appName && normalizeText(element.textContent) === BRANDING.homeAssistantName) {
      replaceExactText(element, BRANDING.homeAssistantName, BRANDING.appName);
    }

    if (BRANDING.appName && normalizeText(element.getAttribute("title")) === BRANDING.homeAssistantName) {
      element.setAttribute("title", BRANDING.appName);
    }

    if (BRANDING.appName && normalizeText(element.getAttribute("aria-label")) === BRANDING.homeAssistantName) {
      element.setAttribute("aria-label", BRANDING.appName);
    }
  });
}

function applyBranding() {
  applyHeadBranding();
  applyTextBranding();
  applyRemoveSelectors();
  applyLogoBranding();
  applyAuthBranding();
}

function scheduleApply() {
  if (scheduledFrame !== null) {
    return;
  }

  scheduledFrame = requestAnimationFrame(() => {
    scheduledFrame = null;
    applyBranding();
  });
}

function observeRoot(root) {
  if (!root || OBSERVED_ROOTS.has(root)) {
    return;
  }

  OBSERVED_ROOTS.add(root);

  const observer = new MutationObserver(() => scheduleApply());
  observer.observe(root, {
    subtree: true,
    childList: true,
    characterData: true,
    attributes: true,
  });

  if (root.querySelectorAll) {
    for (const element of root.querySelectorAll("*")) {
      if (element.shadowRoot) {
        observeRoot(element.shadowRoot);
      }
    }
  }
}

function patchAttachShadow() {
  if (window[SHADOW_PATCH_KEY]) {
    return;
  }

  const originalAttachShadow = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function patchedAttachShadow(init) {
    const root = originalAttachShadow.call(this, init);
    if (init?.mode === "open") {
      observeRoot(root);
      scheduleApply();
    }
    return root;
  };

  window[SHADOW_PATCH_KEY] = true;
}

function init() {
  if (!hasBrandingWork()) {
    return;
  }

  patchAttachShadow();
  observeRoot(document);
  scheduleApply();

  window.addEventListener("popstate", scheduleApply);
  window.addEventListener("hashchange", scheduleApply);
  window.addEventListener("focus", scheduleApply);
  document.addEventListener("visibilitychange", scheduleApply);

  if (BRANDING.auth.enabled && window.matchMedia) {
    const media = window.matchMedia("(prefers-color-scheme: light)");
    if (media.addEventListener) {
      media.addEventListener("change", scheduleApply);
    } else if (media.addListener) {
      media.addListener(scheduleApply);
    }
  }
}

init();
