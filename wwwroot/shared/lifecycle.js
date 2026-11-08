// wwwroot/shared/lifecycle.js
(function () {
  // 1. 画面が開いたことをサーバへ通知（リロードや画面遷移時の終了キャンセル用）
  function sendHeartbeat() {
    fetch('/api/system/heartbeat', { method: 'POST', keepalive: true }).catch(() => {});
  }
  sendHeartbeat();

  // 2. 3秒ごとに生存確認（ハートビート）を送信
  setInterval(sendHeartbeat, 3000);

  // 3. ウィンドウの「×」ボタンやタブ閉鎖時にビーコンを送信
  window.addEventListener('pagehide', () => {
    if (navigator.sendBeacon) {
      navigator.sendBeacon('/api/system/client-closed');
    } else {
      fetch('/api/system/client-closed', { method: 'POST', keepalive: true });
    }
  });
})();