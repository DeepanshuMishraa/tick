// Copies the Homebrew install command; the rest of the page is static.
const button = document.getElementById("copy");
const command = document.getElementById("cmd");

if (button && command) {
  const label = button.textContent;
  let timer;

  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(command.textContent ?? "");
      button.textContent = "copied";
    } catch {
      button.textContent = "copy failed, select it instead";
    }
    clearTimeout(timer);
    timer = setTimeout(() => (button.textContent = label), 1600);
  });
}
