function safeSetTextContent(element, value) {
  if (!element) return
  const textNode = Array.from(element.childNodes).find(
    (node) => node.nodeType === Node.TEXT_NODE && node.textContent.trim().length > 0
  )
  if (!textNode || textNode.textContent === value) return
  textNode.textContent = value
}

let firstFocus = true
let showCodeOverride = null

function isMobile() {
  const clientId = new URL(location.href).searchParams.get("client_id")
  if (!clientId) return false
  return (
    clientId.startsWith("https://home-assistant.io/iOS") ||
    clientId.startsWith("https://home-assistant.io/android")
  )
}

function showCode() {
  if (showCodeOverride !== null) return showCodeOverride
  return isMobile()
}

let ssoButton = null
let codeButton = null
let codeMessage = null
let codeToggle = null
let codeToggleText = null

function update() {
  const ssoName = window.sso_name || "Single Sign-On"
  const loginHeader = document.querySelector(".card-content > ha-auth-flow > form > h1")
  const authForm = document.querySelector("ha-auth-form")
  const codeField = document.querySelector(".mdc-text-field__input[name=code]")
  const haButtons = document.querySelectorAll("ha-button:not(.sso)")
  const errorAlert = document.querySelector("ha-auth-form ha-alert[alert-type=error]")
  const loginOptionList = document.querySelector("ha-pick-auth-provider")?.shadowRoot?.querySelector("ha-list")
  const forgotPasswordLink = document.querySelector(".forgot-password")

  let loginButton = null
  haButtons.forEach((button) => {
    if (button.textContent.trim() === "Log in") {
      loginButton = button
    }
  })

  if (codeField) {
    if (codeField.placeholder !== "One-time code") {
      codeField.placeholder = "One-time code"
      codeField.autofocus = false
      codeField.autocomplete = "off"

      if (firstFocus) {
        firstFocus = false

        if (document.activeElement === codeField) {
          setTimeout(() => {
            codeField.blur()
            const check = setInterval(() => {
              const helperText = document.querySelector("#helper-text")
              const invalidTextField = document.querySelector(".mdc-text-field--invalid")
              const validationMsg = document.querySelector(".mdc-text-field-helper-text--validation-msg")
              if (helperText && invalidTextField && validationMsg) {
                clearInterval(check)
                safeSetTextContent(helperText, "")
                invalidTextField.classList.remove("mdc-text-field--invalid")
                validationMsg.classList.remove("mdc-text-field-helper-text--validation-msg")
              }
            }, 1)
          }, 0)
        }
      }
    }

    if (errorAlert && errorAlert.textContent.trim().length === 0) {
      errorAlert.setAttribute("title", "Invalid Code")
    }

    if (authForm) {
      authForm.style.display = showCode() ? "" : "none"
    }
  }

  if (authForm && authForm.parentElement && !codeMessage) {
    codeMessage = document.createElement("p")
    codeMessage.innerHTML = "<b>Please login on a different device to continue.</b><br/>You can also use your mobile web browser."
    authForm.parentElement.insertBefore(codeMessage, authForm)
  }

  if (codeMessage) {
    codeMessage.style.display = showCode() ? "" : "none"
  }

  if (showCode() && loginButton !== null && !codeButton) {
    codeButton = document.createElement("ha-button")
    codeButton.id = "code_button"
    codeButton.classList.add("code")
    codeButton.innerText = "Log in with code"
    codeButton.setAttribute("raised", "")
    codeButton.style.marginRight = "1em"
    codeButton.addEventListener("click", () => {
      loginButton.click()
    })
    loginButton.parentElement.prepend(codeButton)
  } else if (!showCode() && loginButton !== null && codeButton) {
    codeButton.remove()
    codeButton = null
  }

  if (loginOptionList && !codeToggle && !isMobile()) {
    codeToggle = document.createElement("ha-list-item")
    codeToggle.setAttribute("hasmeta", "")
    codeToggleText = document.createTextNode("")
    codeToggle.appendChild(codeToggleText)
    const codeToggleIcon = document.createElement("ha-icon-next")
    codeToggleIcon.setAttribute("slot", "meta")
    codeToggle.appendChild(codeToggleIcon)

    let ranHandler = false
    codeToggle.addEventListener("click", () => {
      ranHandler = true
      showCodeOverride = !showCode()
      update()
    })

    loginOptionList.addEventListener("click", () => {
      if (!ranHandler) {
        showCodeOverride = false
        codeMessage = null
      }
      ranHandler = false
    })

    loginOptionList.appendChild(codeToggle)
  }

  if (codeToggle) {
    codeToggle.style.display = codeField ? "" : "none"
  }

  if (codeToggleText) {
    codeToggleText.textContent = showCode() ? "Single-Sign On" : "One-time device code"
  }

  const shouldShowSsoButton = !showCode() && !!codeField
  const isOurScreen = showCode() || shouldShowSsoButton

  if (loginButton !== null && !ssoButton) {
    ssoButton = document.createElement("ha-button")
    ssoButton.id = "sso_button"
    ssoButton.classList.add("sso")
    ssoButton.innerText = "Log in with " + ssoName
    ssoButton.setAttribute("raised", "")
    ssoButton.style.marginRight = "1em"
    ssoButton.addEventListener("click", () => {
      const params = new URL(location.href).searchParams
      const redirectUrl = "/auth/oidc/redirect"
      const queryParams = new URLSearchParams()

      if (params.has("client_id")) queryParams.set("client_id", params.get("client_id"))
      if (params.has("redirect_uri")) queryParams.set("redirect_uri", params.get("redirect_uri"))
      if (params.has("state")) queryParams.set("state", params.get("state"))

      location.href = queryParams.toString()
        ? `${redirectUrl}?${queryParams.toString()}`
        : redirectUrl
      ssoButton.innerHTML = "Redirecting, please wait..."
      ssoButton.disabled = true
    })
    loginButton.parentElement.prepend(ssoButton)
  }

  if (ssoButton) {
    ssoButton.style.display = shouldShowSsoButton ? "" : "none"
  }

  if (loginHeader) {
    if (isOurScreen) {
      loginHeader.style.display = "none"
      if (loginButton !== null) {
        loginButton.style.display = "none"
      }
      if (forgotPasswordLink) {
        forgotPasswordLink.style.display = "none"
      }
    } else {
      loginHeader.style.display = ""
      if (loginButton !== null) {
        loginButton.style.display = ""
      }
      if (forgotPasswordLink) {
        forgotPasswordLink.style.display = ""
      }
    }
  }

  if (
    !document.body.dataset.autoLoginTriggered &&
    !window.location.href.includes("code=") &&
    ssoButton &&
    !ssoButton.disabled
  ) {
    document.body.dataset.autoLoginTriggered = "true"
    setTimeout(() => {
      ssoButton.click()
    }, 100)
  }
}

const revealContent = () => {
  const content = document.querySelector(".content")
  if (content !== null) {
    content.style.display = ""
  }
}

const hideContent = () => {
  const content = document.querySelector(".content")
  if (content !== null) {
    content.style.display = "none"
  }
}

const isReady = () => Boolean(ssoButton && codeMessage && codeToggle && codeToggleText)

let ready = false
hideContent()

const observer = new MutationObserver(() => {
  update()

  if (!ready) {
    ready = isReady()
    if (ready) revealContent()
  }
})

observer.observe(document.body, { childList: true, subtree: true })

setTimeout(() => {
  if (!ready) {
    ready = isReady()
  }
  revealContent()
  update()
}, 1500)
