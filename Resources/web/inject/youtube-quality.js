// YouTube quality, page world, main frame: when a video starts playing, the player gets the
// preferred quality (content.youtubeQuality), capped at what the video has, as if picked in its
// quality menu. Once per video, so a quality chosen by hand afterwards stays.
(() => {
  if (window.__anglYouTubeQuality) return;
  window.__anglYouTubeQuality = true;
  const want = '__ANGL_YT_QUALITY__';
  const order = ['tiny', 'small', 'medium', 'large', 'hd720', 'hd1080', 'hd1440', 'hd2160', 'hd2880', 'highres'];
  const cap = order.indexOf(want);
  let done = '';
  const apply = (e) => {
    const player = document.getElementById('movie_player');
    if (cap < 0 || !player || !player.contains(e.target) || typeof player.getAvailableQualityLevels !== 'function') return;
    const id = player.getVideoData?.()?.video_id;
    if (!id || id === done) return;
    // Best first; 'auto' and unknown names don't count.
    const pick = player.getAvailableQualityLevels().find((q) => { const i = order.indexOf(q); return i >= 0 && i <= cap; });
    if (!pick) return;
    done = id;
    player.setPlaybackQualityRange?.(pick, pick);
    player.setPlaybackQuality?.(pick);
  };
  // Media events don't bubble; capture sees every video's.
  document.addEventListener('playing', apply, true);
})();
