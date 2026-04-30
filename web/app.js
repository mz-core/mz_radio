const resourceName =
  typeof GetParentResourceName === "function"
    ? GetParentResourceName()
    : "mz_radio";

const app = document.getElementById("app");
const form = document.getElementById("radioForm");
const input = document.getElementById("frequencyInput");
const statusText = document.getElementById("statusText");
const currentFrequency = document.getElementById("currentFrequency");
const connectionBadge = document.getElementById("connectionBadge");
const quickChannels = document.getElementById("quickChannels");
const quickCount = document.getElementById("quickCount");
const closeButton = document.getElementById("closeButton");
const saveButton = document.getElementById("saveButton");
const leaveButton = document.getElementById("leaveButton");
const powerButton = document.getElementById("powerButton");

let savedChannels = [];
let connected = false;

function post(action, data = {}) {
  return fetch(`https://${resourceName}/${action}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json; charset=UTF-8",
    },
    body: JSON.stringify(data),
  }).then((response) => response.json());
}

function formatFrequency(value) {
  const number = Number(value);

  if (!number || number <= 0) {
    return "OFF";
  }

  return `${number.toFixed(1)} MHz`;
}

function normalizeFrequency(value) {
  const number = Number(value);

  if (!Number.isFinite(number) || number <= 0) {
    return null;
  }

  return Number(number.toFixed(1));
}

function saveCurrentChannel() {
  const frequency = normalizeFrequency(input.value);

  if (!frequency) {
    input.focus();
    return;
  }

  post("saveChannel", { frequency }).then((result) => {
    if (result && Array.isArray(result.channels)) {
      savedChannels = result.channels;
      renderChannels();
    }
  });
}

function removeSavedChannel(frequency) {
  post("removeSavedChannel", { frequency }).then((result) => {
    if (result && Array.isArray(result.channels)) {
      savedChannels = result.channels;
      renderChannels();
    }
  });
}

function renderChannels() {
  quickChannels.innerHTML = "";
  quickCount.textContent = String(savedChannels.length);

  if (!savedChannels.length) {
    const empty = document.createElement("div");
    empty.className = "quick-channel empty-channel";
    empty.innerHTML = "<strong>Nenhum canal salvo</strong><span>Digite a frequencia e clique em +</span>";
    quickChannels.appendChild(empty);
    return;
  }

  savedChannels.forEach((channel) => {
    const row = document.createElement("div");
    const formattedFrequency = formatFrequency(channel.frequency);
    const label =
      channel.label && channel.label !== formattedFrequency
        ? channel.label
        : "Canal salvo";

    row.className = "quick-channel saved-channel";
    row.innerHTML = `
      <button class="channel-connect" type="button" aria-label="Conectar em ${formattedFrequency}">
        <strong>${label}</strong>
        <span>${formattedFrequency}</span>
      </button>
      <button class="channel-remove" type="button" aria-label="Remover ${formattedFrequency}">x</button>
    `;

    row.querySelector(".channel-connect").addEventListener("click", () => {
      input.value = Number(channel.frequency).toFixed(1);
      post("join", { frequency: channel.frequency });
    });

    row.querySelector(".channel-remove").addEventListener("click", () => {
      removeSavedChannel(channel.frequency);
    });

    quickChannels.appendChild(row);
  });
}

function renderState(data = {}) {
  connected = data.connected === true;
  const channel = Number(data.channel) || 0;

  statusText.textContent = connected ? "Conectado" : "Desconectado";
  currentFrequency.textContent = data.channelLabel || formatFrequency(channel);
  connectionBadge.textContent = connected ? "Online" : "Standby";
  connectionBadge.classList.toggle("connected", connected);

  if (Array.isArray(data.savedChannels)) {
    savedChannels = data.savedChannels;
  }

  if (connected && channel > 0) {
    input.value = channel.toFixed(1);
  }

  renderChannels();
}

function openRadio(data = {}) {
  app.classList.add("open");
  app.setAttribute("aria-hidden", "false");
  renderState(data);
  setTimeout(() => input.focus(), 80);
}

function closeRadio() {
  app.classList.remove("open");
  app.setAttribute("aria-hidden", "true");
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  post("join", { frequency: input.value });
});

closeButton.addEventListener("click", () => post("close"));
saveButton.addEventListener("click", saveCurrentChannel);
leaveButton.addEventListener("click", () => post("leave"));
powerButton.addEventListener("click", () => post("leave"));

document.addEventListener("keyup", (event) => {
  if (event.key === "Escape") {
    post("close");
  }
});

window.addEventListener("message", (event) => {
  const data = event.data || {};

  if (data.action === "open") {
    openRadio(data);
    return;
  }

  if (data.action === "close") {
    closeRadio();
    return;
  }

  if (data.action === "state") {
    renderState(data);
  }
});

renderChannels();
post("ready").catch(() => {});
