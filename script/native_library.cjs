// Run with the pinned podkit executable in Bun runtime mode. No Node installation required.
const fs = require('fs');
const path = require('path');
function fail(message) { throw new Error(message); }
function nativeBinding() {
  const executable = fs.realpathSync(process.execPath);
  const target = path.join(path.dirname(executable), 'musicbridge-libgpod.node');
  const stamp = executable + ':' + fs.statSync(executable).size + ':' + fs.statSync(executable).mtimeMs;
  if (!fs.existsSync(target) || !fs.existsSync(target + '.stamp') || fs.readFileSync(target + '.stamp', 'utf8') !== stamp) {
    const data = fs.readFileSync(executable), magic = Buffer.from([0xcf, 0xfa, 0xed, 0xfe]);
    let start = 0, extracted = false;
    while ((start = data.indexOf(magic, start)) >= 0) {
      const offset = start; start += 4;
      if (offset + 32 > data.length) continue;
      const type = data.readUInt32LE(offset + 12), commands = data.readUInt32LE(offset + 16);
      if (![6, 8].includes(type) || commands > 100) continue;
      let position = offset + 32, end = 0, valid = true;
      for (let i = 0; i < commands; i++) {
        if (position + 8 > data.length) { valid = false; break; }
        const cmd = data.readUInt32LE(position), size = data.readUInt32LE(position + 4);
        if (size < 8 || size > 10000 || position + size > data.length) { valid = false; break; }
        if (cmd === 0x19 && size >= 72) end = Math.max(end, Number(data.readBigUInt64LE(position + 40) + data.readBigUInt64LE(position + 48)));
        if (cmd === 0x1d && size >= 16) end = Math.max(end, data.readUInt32LE(position + 8) + data.readUInt32LE(position + 12));
        position += size;
      }
      if (valid && end > 0 && end < 64 * 1024 * 1024 && offset + end <= data.length) {
        const temporary = target + '.' + process.pid;
        fs.writeFileSync(temporary, data.subarray(offset, offset + end), {mode: 0o600});
        fs.renameSync(temporary, target); fs.writeFileSync(target + '.stamp', stamp);
        extracted = true; break;
      }
    }
    if (!extracted) fail('无法加载当前引擎的原生曲库模块，请重新安装 podkit 0.6.0。');
  }
  return require(target);
}
const norm = value => (value || '').normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
function matches(song, track) {
  const a = norm(song.artist), b = norm(track.artist);
  return norm(song.title) === norm(track.title) && a && b && (a === b || a.includes(b) || b.includes(a))
    && (!song.album || norm(song.album) === norm(track.album));
}
function filesFor(root, tracks) {
  return tracks.map(track => {
    const relative = (track.ipodPath || '').replaceAll(':', '/').replace(/^\/+/, '');
    if (!relative.startsWith('iPod_Control/Music/') || relative.split('/').some(p => p === '..')) fail('设备歌曲路径无效。');
    const file = path.join(root, relative);
    if (fs.realpathSync(file) !== file || !fs.statSync(file).isFile() || fs.statSync(file).size !== track.size) fail('设备歌曲文件缺失或大小不符，请保留连接并重试校验。');
    return {relative, size: track.size, artwork: !!track.hasArtwork};
  });
}
try {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const root = input.mount;
  if (typeof root !== 'string' || fs.realpathSync(root) !== root) fail('设备路径已变化。');
  const binding = nativeBinding();
  let db;
  try {
    if (input.action === 'initialize') {
      const models = {video_1:'MA002', video_2:'MA446', classic_1:'MB029', classic_2:'MB565', classic_3:'MC293'};
      const model = models[input.profile];
      if (!model || !/^[a-fA-F0-9]{16}$/.test(input.hardwareIdentifier || '')) fail('机型或真实硬件标识缺失，未初始化。');
      for (const name of ['iTunesDB','iTunesCDB']) if (fs.existsSync(path.join(root, 'iPod_Control/iTunes', name))) fail('原生曲库已经存在，未覆盖。');
      const info = path.join(root, 'iPod_Control/Device/SysInfo');
      fs.mkdirSync(path.dirname(info), {recursive:true});
      if (fs.realpathSync(path.dirname(info)) !== path.dirname(info) || (fs.existsSync(info) && fs.lstatSync(info).isSymbolicLink())) fail('设备信息路径无效。');
      const original = fs.existsSync(info) ? fs.readFileSync(info, 'utf8') : '';
      const retained = original.split(/\r?\n/).filter(line => line && !/^(ModelNumStr|FirewireGuid):/.test(line));
      fs.writeFileSync(path.join(root, 'iPod_Control/Device/MusicBridgeIdentity.json'), JSON.stringify({
        schema:1, configuredProfileID:input.profile, writtenModelCode:model.slice(1), originalProfileID:input.detectedProfile || null
      }));
      fs.writeFileSync(info, [...retained, 'ModelNumStr: ' + model, 'FirewireGuid: 0x' + input.hardwareIdentifier, ''].join('\n'));
      db = binding.initIpod(root, model, input.name || 'iPod');
      if (db.getTracks().length !== 0) fail('初始化后曲目数量异常。');
      db.close(); db = binding.parse(root);
      if (db.getTracks().length !== 0) fail('空曲库回读失败。');
      console.log(JSON.stringify({success:true, tracks:0}));
    } else if (['playlist-preview','playlist-save'].includes(input.action)) {
      db = binding.parse(root);
      const selection = input.playlist;
      if (!selection || !selection.name || !Array.isArray(selection.tracks) || selection.tracks.length > 10000) fail('歌单记录无效。');
      const tracks = db.getTracks().map(handle => ({handle, data:db.getTrackData(handle)}));
      const ordered = [], used = new Set();
      for (const song of selection.tracks) {
        const candidates = tracks.filter(track => matches(song, track.data));
        if (candidates.length === 1 && !used.has(candidates[0].handle)) { ordered.push(candidates[0]); used.add(candidates[0].handle); }
      }
      let list = db.getPlaylistByName(selection.name);
      if (list && (list.isMaster || list.isSmart || list.isPodcasts)) fail('同名列表是系统列表，歌曲已保留，请更改歌单名称后重试。');
      const old = list ? db.getPlaylistTracks(list.id) : [];
      if (old.some(handle => !used.has(handle))) fail('同名播放列表含其他歌曲，未覆盖。歌曲已导入，请先更改列表名称再重试。');
      const files = filesFor(root, ordered.map(t => t.data));
      const changed = ordered.length > 0 && (!list || old.length !== ordered.length || old.some((h,i) => h !== ordered[i].handle));
      if (input.action === 'playlist-save' && changed) {
        list ||= db.createPlaylist(selection.name);
        for (const handle of old) db.removeTrackFromPlaylist(list.id, handle);
        for (const track of ordered) db.addTrackToPlaylist(list.id, track.handle);
        db.write(); db.close(); db = binding.parse(root);
        const saved = db.getPlaylistByName(selection.name);
        const actual = saved ? db.getPlaylistTracks(saved.id).map(h => db.getTrackData(h)) : [];
        if (actual.length !== ordered.length || actual.some((t,i) => String(t.dbid) !== String(ordered[i].data.dbid))) fail('播放列表回读顺序不符，请保留连接检查。');
        if (db.getTracks().length !== tracks.length) fail('播放列表操作后的曲目数量不符。');
      }
      console.log(JSON.stringify({success:true, changed, count:ordered.length, files, titles:ordered.map(t => t.data.title)}));
    } else fail('未知的曲库操作。');
  } finally { if (db) db.close(); }
} catch (error) {
  // Device identifiers and native exception text never leave this helper.
  const safe = error.message && /[\u3400-\u9fff]/.test(error.message) ? error.message : '原生曲库操作未完成，请保留连接并检查备份。';
  console.log(JSON.stringify({success:false, error:safe})); process.exitCode = 1;
}
