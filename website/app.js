const platformData = {
  mac: {image: 'assets/phrases.png', caption: 'Mac 实际运行截图 · App 自带常用表达', alt: 'Mac 的客户沟通常用表达界面', width: 2320, height: 1580},
  windows: {image: 'assets/windows-workspace-preview.png', caption: 'Windows 界面组件预览 · 示例文字，实机验证范围见下载说明', alt: 'Windows 翻译工作台组件预览，内容为布局示例', width: 904, height: 581}
};
document.querySelectorAll('[data-platform]').forEach(button => {
  button.addEventListener('click', () => {
    const data = platformData[button.dataset.platform];
    document.querySelectorAll('[data-platform]').forEach(other => other.setAttribute('aria-pressed', String(other === button)));
    const image = document.querySelector('#platform-image');
    Object.assign(image, {src: data.image, alt: data.alt, width: data.width, height: data.height});
    document.querySelector('#platform-caption').textContent = data.caption;
    const screen = document.querySelector('#platform-screen');
    screen.dataset.image = data.image;
    screen.dataset.caption = data.caption;
  });
});
document.querySelectorAll('[data-setup]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-setup]').forEach(other => other.setAttribute('aria-pressed', String(other === button)));
    ['windows', 'mac'].forEach(platform => {document.querySelector(`#${platform}-steps`).hidden = platform !== button.dataset.setup;});
  });
});
document.querySelectorAll('.screenshot-button').forEach(button => {
  button.addEventListener('click', () => {
    const dialog = document.querySelector('#image-dialog');
    document.querySelector('#dialog-image').src = button.dataset.image;
    document.querySelector('#dialog-image').alt = button.querySelector('img').alt;
    document.querySelector('#dialog-caption').textContent = button.dataset.caption;
    dialog.showModal();
  });
});
document.querySelector('#support-open').addEventListener('click', () => document.querySelector('#support-dialog').showModal());
document.querySelectorAll('dialog').forEach(dialog => {
  dialog.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => {
    const bounds = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) dialog.close();
  });
});
document.querySelector('.copy-hash').addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#installer-hash').textContent);
    status.textContent = '已复制';
  } catch {
    status.textContent = '请选中上方校验值复制';
  }
});
