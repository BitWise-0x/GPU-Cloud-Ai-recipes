// ComfyUI sends each upload as one multipart POST to /upload/image. Over the SSH tunnel a large
// video takes minutes, a dropped tunnel restarts it from zero and nothing shows how far it got;
// through Cloudflare a request over 100 MB is refused. Every upload is sent here instead, in
// chunks to /media_library/upload, resumed from the server's offset after a drop, with a progress
// panel in the bottom-left corner, then committed where /upload/image would have put it. The
// node that asked gets the answer /upload/image gives.
(() => {
	const native_fetch = window.fetch.bind(window);
	const comfy_upload_pattern = /\/upload\/image$/;
	const chunk_size_min = 256 * 1024;
	// 32 MB keeps each chunk under Cloudflare's per-request edge window on a slow uplink,
	// so a chunk is not cut mid-flight while the connection is busy; the chunk is still
	// auto-sized to chunk_seconds, this is only the ceiling a fast link is capped at
	const chunk_size_max = 32 * 1024 * 1024;
	// size each chunk to take about this long, so a drop loses little and a fast link is not
	// slowed down by one request per small chunk
	const chunk_seconds = 4;
	const retry_delay_max = 15000;
	const retry_attempts_max = 40;
	// files go one at a time per lane: photos, and videos and anything else, each have their own,
	// so a photo never waits behind a multi-GB video
	const sample_size = 1024 * 1024;
	const queues = { image: Promise.resolve(), other: Promise.resolve() };
	const done_color = '#27ae60';
	const failed_color = '#c0392b';
	const waiting_color = '#e67e22';
	// rows the collapsed panel shows; the rest show once the arrow expands it
	const collapsed_rows = 2;
	const state_labels = { active: 'uploading', waiting: 'waiting', queued: 'queued', failed: 'failed', done: 'done' };
	const panel_css = '.upload-status{position:fixed;left:max(12px, env(safe-area-inset-left));bottom:calc(max(12px, env(safe-area-inset-bottom)) + 44px);' +
		'z-index:10000;display:flex;flex-direction:column;gap:8px;padding:8px 12px;box-sizing:border-box;width:min(380px, calc(100vw - 24px));' +
		'border-radius:10px;font:13px/1.35 system-ui,sans-serif;color:#fff;background:rgba(20,20,24,.92);box-shadow:0 2px 10px rgba(0,0,0,.35)}' +
		'.upload-status.is-idle{display:none}' +
		'.upload-status-header{display:flex;align-items:center;gap:8px;min-height:28px}' +
		'.upload-status-title{font-weight:600;letter-spacing:.04em}' +
		'.upload-status-summary{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;opacity:.75}' +
		'.upload-status-toggle{flex:none;min-width:44px;min-height:44px;margin:-12px -8px -12px 0;border:0;background:none;color:inherit;font-size:18px;cursor:pointer;transition:transform .2s}' +
		'.upload-status.is-expanded .upload-status-toggle{transform:rotate(180deg)}' +
		'.upload-status-list{display:flex;flex-direction:column;gap:8px}' +
		'.upload-status:not(.is-expanded) .upload-status-row:nth-child(n + 3){display:none !important}' +
		'.upload-status.is-expanded .upload-status-list{max-height:60vh;overflow-y:auto}';
	let panel = null;

	// the same file dropped again maps to the same upload: the key comes from the name, the size
	// and sampled bytes
	const create_key = async (file) => {
		const head = new Uint8Array(await file.slice(0, sample_size).arrayBuffer());
		const tail = new Uint8Array(await file.slice(Math.max(0, file.size - sample_size)).arrayBuffer());
		const text = new TextEncoder().encode(file.name + '|' + file.size + '|');
		let hash_a = 0x811c9dc5;
		let hash_b = 0x01000193;
		for (const bytes of [ text, head, tail ]) {
			for (let index = 0; index < bytes.length; index++) {
				hash_a = Math.imul(hash_a ^ bytes[index], 0x01000193) >>> 0;
				hash_b = Math.imul(hash_b ^ bytes[index], 0x5bd1e995) >>> 0;
			}
		}
		return hash_a.toString(16).padStart(8, '0') + hash_b.toString(16).padStart(8, '0');
	};

	const format_size = (bytes) => {
		const units = [ 'B', 'KB', 'MB', 'GB' ];
		let value = bytes;
		let unit = 0;
		while (value >= 1024 && unit < units.length - 1) {
			value /= 1024;
			unit++;
		}
		return value.toFixed(unit > 1 ? 1 : 0) + ' ' + units[unit];
	};

	const format_duration = (seconds) => {
		if (!isFinite(seconds)) {
			return '';
		}
		if (seconds < 60) {
			return Math.ceil(seconds) + 's';
		}
		if (seconds < 3600) {
			return Math.floor(seconds / 60) + 'm ' + Math.round(seconds % 60) + 's';
		}
		return Math.floor(seconds / 3600) + 'h ' + Math.round(seconds % 3600 / 60) + 'm';
	};

	const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

	// floating in the bottom-left corner while files go up, collapsed to a few rows with an
	// arrow that shows every upload
	const get_panel = () => {
		if (!panel) {
			const style = document.createElement('style');
			style.textContent = panel_css;
			document.head.appendChild(style);
			panel = document.createElement('div');
			panel.className = 'upload-status is-idle';
			panel.innerHTML = '<div class="upload-status-header"><span class="upload-status-title">UPLOADS</span>' +
				'<span class="upload-status-summary" role="status" aria-live="polite"></span>' +
				'<button type="button" class="upload-status-toggle" aria-expanded="false" aria-label="show every upload">&#9662;</button></div>' +
				'<div class="upload-status-list"></div>';
			panel.querySelector('.upload-status-toggle').addEventListener('click', (event) => {
				const is_expanded = panel.classList.toggle('is-expanded');
				event.currentTarget.setAttribute('aria-expanded', String(is_expanded));
				event.currentTarget.setAttribute('aria-label', is_expanded ? 'show fewer uploads' : 'show every upload');
				update_panel();
			});
			document.body.appendChild(panel);
		}
		return panel;
	};

	const update_panel = () => {
		const rows = [ ...panel.querySelector('.upload-status-list').children ];
		const counts = {};
		rows.forEach((row) => {
			counts[row.dataset.state] = (counts[row.dataset.state] || 0) + 1;
		});
		const parts = Object.keys(state_labels).filter((state) => counts[state]).map((state) => counts[state] + ' ' + state_labels[state]);
		if (rows.length > collapsed_rows && !panel.classList.contains('is-expanded')) {
			parts.push('+' + (rows.length - collapsed_rows) + ' more');
		}
		panel.querySelector('.upload-status-summary').textContent = parts.length ? parts.join(' · ') : 'none in progress';
		panel.classList.toggle('is-idle', !rows.length);
	};

	// one row per file. its x cancels: the request in flight is aborted, a queued file is
	// skipped, and on_cancel discards what already reached the server
	const create_row = (name, size, on_cancel) => {
		const row = document.createElement('div');
		row.className = 'upload-status-row';
		row.dataset.state = 'queued';
		row.style.cssText = 'display:flex;gap:6px;align-items:flex-start';
		row.innerHTML = '<div style="flex:1;min-width:0"><div style="display:flex;justify-content:space-between;gap:8px">' +
			'<span style="font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span>' +
			'<span style="flex:none;opacity:.75"></span></div>' +
			'<div style="height:4px;margin-top:4px;border-radius:2px;background:rgba(255,255,255,.15)">' +
			'<div style="height:100%;width:0;border-radius:2px;background:' + done_color + ';transition:width .3s"></div></div>' +
			'<div style="margin-top:3px;opacity:.75"></div></div>' +
			'<button type="button" aria-label="cancel upload" style="flex:none;min-width:44px;min-height:44px;margin:-10px -8px -10px 0;' +
			'border:0;background:none;color:inherit;opacity:.7;font:20px/1 system-ui,sans-serif;cursor:pointer">&times;</button>';
		const details = row.children[0];
		details.children[0].children[0].textContent = name;
		details.children[0].children[1].textContent = format_size(size);
		get_panel().querySelector('.upload-status-list').appendChild(row);

		const bar = details.children[1].firstChild;
		const note = details.children[2];
		const remove = () => {
			row.remove();
			update_panel();
		};
		const handle = {
			cancelled: false,
			controller: null,
			key: null,
			on_fraction: null,
			update: (fraction, text, color) => {
				if (handle.on_fraction) {
					handle.on_fraction(fraction);
				}
				bar.style.width = Math.round(fraction * 100) + '%';
				bar.style.background = color || done_color;
				note.textContent = text;
				row.dataset.state = color === failed_color ? 'failed' : color === waiting_color ? 'waiting' : text === 'queued' ? 'queued' : fraction >= 1 ? 'done' : 'active';
				update_panel();
			},
			remove: remove,
			remove_later: () => setTimeout(remove, 3000)
		};
		row.lastChild.addEventListener('click', () => {
			handle.cancelled = true;
			if (handle.controller) {
				handle.controller.abort();
			}
			remove();
			if (on_cancel) {
				on_cancel(handle);
			}
		});
		update_panel();
		return handle;
	};

	// a chunk still arriving holds the server's lock for a moment after its request is aborted
	const discard_upload = async (base_url, key) => {
		for (let attempt = 0; key && attempt < 10; attempt++) {
			const response = await native_fetch(base_url + '/media_library/upload/' + key, { method: 'DELETE' }).catch(() => null);
			if (response && response.status !== 409) {
				return;
			}
			await sleep(1000);
		}
	};

	const read_json = async (response) => {
		try {
			return await response.json();
		} catch (error) {
			return {};
		}
	};

	// a dropped tunnel can leave a request hanging with no error, so every request gets a
	// deadline scaled to the bytes it carries
	const timed_fetch = (url, options, timeout, row) => {
		const controller = new AbortController();
		const timer = setTimeout(() => controller.abort(), timeout);
		if (row) {
			row.controller = controller;
		}
		return native_fetch(url, { ...options, signal: controller.signal, cache: 'no-store' }).finally(() => clearTimeout(timer));
	};

	const is_retryable = (status) => status === 408 || status === 429 || status >= 500 && status !== 507;

	const upload_file = async (base_url, file, row) => {
		const query = '?name=' + encodeURIComponent(file.name) + '&size=' + file.size;
		row.key = await create_key(file);
		// dropping a file again continues it: its "unfinished" row from the last page load goes
		if (unfinished_rows[row.key]) {
			unfinished_rows[row.key].remove();
			delete unfinished_rows[row.key];
		}
		const url = base_url + '/media_library/upload/' + row.key + query;
		let offset = null;
		let chunk_size = 1024 * 1024;
		let rate = 0;
		let attempts = 0;

		while (true) {
			try {
				let response;
				let started = 0;
				let sent = 0;

				if (row.cancelled) {
					throw Object.assign(new Error('cancelled'), { cancelled: true });
				}
				if (offset === null) {
					response = await timed_fetch(url, { method: 'GET' }, 20000, row);
				} else {
					sent = Math.min(chunk_size, file.size - offset);
					started = performance.now();
					const timeout = 30000 + (rate ? sent / rate * 4000 : 120000);
					response = await timed_fetch(url + '&offset=' + offset, {
						method: 'PUT',
						headers: { 'Content-Type': 'application/octet-stream' },
						body: file.slice(offset, offset + sent)
					}, timeout, row);
				}
				const result = await read_json(response);

				if (offset === null && (response.status === 404 || response.status === 405)) {
					throw Object.assign(new Error('chunked upload route missing'), { unsupported: true });
				}
				if (response.status === 409 && Number.isInteger(result.offset)) {
					offset = result.offset;
					continue;
				}
				if (response.ok && !result.done && !Number.isInteger(result.offset)) {
					throw new Error('unexpected server answer');
				}
				if (!response.ok) {
					if (is_retryable(response.status)) {
						throw Object.assign(new Error('server answered ' + response.status), { status: response.status });
					}
					throw Object.assign(new Error(result.error || 'upload refused (' + response.status + ')'), { fatal: true });
				}
				if (result.done) {
					row.update(1, offset === null ? 'already on the server' : 'done');
					return query;
				}
				if (offset !== null && result.offset > offset) {
					const seconds = (performance.now() - started) / 1000;
					rate = (result.offset - offset) / Math.max(seconds, 0.05);
					chunk_size = Math.min(chunk_size_max, Math.max(chunk_size_min, Math.round(rate * chunk_seconds)));
				}
				offset = result.offset;
				attempts = 0;
				const left = rate ? format_duration((file.size - offset) / rate) + ' left' : '';
				row.update(offset / file.size, Math.floor(offset / file.size * 100) + '%' + (rate ? ' · ' + format_size(rate) + '/s · ' + left : ''));
			} catch (error) {
				if (error.unsupported || row.cancelled) {
					throw row.cancelled ? Object.assign(new Error('cancelled'), { cancelled: true }) : error;
				}
				if (error.fatal || ++attempts > retry_attempts_max) {
					row.update(offset ? offset / file.size : 0, 'failed: ' + error.message, failed_color);
					throw error;
				}
				const delay = Math.min(retry_delay_max, 1000 * 2 ** (attempts - 1));
				// 429: an earlier attempt of this file is still open on the server (it gives up
				// on a silent one after a minute), which is not a lost connection
				const reason = error.status === 429 ? 'the server is still closing an earlier attempt' : 'connection lost';
				row.update(offset ? offset / file.size : 0, reason + ', resuming in ' + Math.round(delay / 1000) + 's', waiting_color);
				await sleep(delay);
				// ask the server how much arrived instead of trusting the failed request
				offset = null;
			}
		}
	};

	// the finished file goes where /upload/image would have put it: the same form fields, minus
	// the file itself
	const commit_file = async (base_url, row, query, form) => {
		for (let attempt = 1; ; attempt++) {
			const fields = new FormData();
			[ 'subfolder', 'type', 'overwrite' ].forEach((field) => {
				if (form.has(field)) {
					fields.append(field, form.get(field));
				}
			});
			const response = await timed_fetch(base_url + '/media_library/commit/' + row.key + query, { method: 'POST', body: fields }, 120000, row).catch((error) => ({ ok: false, status: 0, error }));
			if (response.ok || !is_retryable(response.status) && response.status !== 0 || attempt >= 5) {
				return response;
			}
			row.update(1, 'saving, connection lost, retrying', waiting_color);
			await sleep(1000 * attempt);
		}
	};

	// one upload the page meant for /upload/image: sent in chunks, then committed. resolves to
	// the status and body /upload/image would have answered, or to { unsupported: true } when
	// the pod has no chunked upload route, so the caller sends it the old way
	const run_upload = (url, form, on_fraction) => {
		const file = form.get('image');
		const base_url = url.origin + url.pathname.replace(comfy_upload_pattern, '');
		const lane = file.type.startsWith('image/') ? 'image' : 'other';
		const row = create_row(file.name, file.size, (handle) => discard_upload(base_url, handle.key));
		row.update(0, 'queued');
		row.on_fraction = on_fraction;
		const task = queues[lane].then(async () => {
			try {
				if (row.cancelled) {
					throw Object.assign(new Error('upload cancelled'), { cancelled: true });
				}
				const query = await upload_file(base_url, file, row);
				const response = await commit_file(base_url, row, query, form);
				if (!response.ok) {
					row.update(1, 'failed: the server did not save it (' + response.status + ')', failed_color);
					return { status: response.status || 500, text: 'upload not saved' };
				}
				return { status: 200, text: await response.text() };
			} catch (error) {
				if (error.unsupported) {
					row.update(0, 'uploading in one request');
					return { unsupported: true };
				}
				return { status: error.cancelled ? 499 : 500, text: error.cancelled ? 'upload cancelled' : error.message };
			} finally {
				row.remove_later();
			}
		});
		queues[lane] = task.catch(() => null);
		return task;
	};

	const is_comfy_upload = (url, method, body) => String(method).toUpperCase() === 'POST' && body instanceof FormData && comfy_upload_pattern.test(url.pathname) && body.get('image') instanceof File;

	const to_url = (input) => new URL(typeof input === 'string' || input instanceof URL ? input : input.url, window.location.href);

	// uploads a reload interrupted stay on the server as partial files: list them, with an x to
	// discard and a note that dropping the same file again continues it
	const unfinished_rows = {};

	const show_unfinished = async () => {
		const base_url = window.location.origin + window.location.pathname.replace(/\/$/, '') + '/api';
		const response = await native_fetch(base_url + '/media_library/partials', { cache: 'no-store' }).catch(() => null);
		const result = response && response.ok ? await read_json(response) : {};
		(result.partials || []).forEach((partial) => {
			if (unfinished_rows[partial.key] || !partial.size) {
				return;
			}
			const row = create_row(partial.name, partial.size, () => {
				delete unfinished_rows[partial.key];
				discard_upload(base_url, partial.key);
			});
			row.update(partial.received / partial.size, 'unfinished: drop the same file again to continue it', waiting_color);
			unfinished_rows[partial.key] = row;
		});
	};

	setTimeout(show_unfinished, 1500);

	// the frontend resolves fetch on every call, so its uploads come through here; one file per
	// request, in the "image" field, whatever its type
	window.fetch = (input, init) => {
		const url = to_url(input);
		if (init && is_comfy_upload(url, init.method, init.body)) {
			return run_upload(url, init.body).then((result) => result.unsupported ? native_fetch(input, init) : new Response(result.text, { status: result.status, headers: { 'Content-Type': 'application/json' } }));
		}
		return native_fetch(input, init);
	};

	// VideoHelperSuite's Load Video uploads with XMLHttpRequest, for its progress bar: the
	// request is answered here once the file is committed, with its progress events from the
	// chunks, and the status and responseText /upload/image would have given
	const native_open = XMLHttpRequest.prototype.open;
	const native_send = XMLHttpRequest.prototype.send;

	XMLHttpRequest.prototype.open = function (method, url, ...rest) {
		this.upload_target = { method: method, url: to_url(url) };
		return native_open.call(this, method, url, ...rest);
	};

	XMLHttpRequest.prototype.send = function (body) {
		const target = this.upload_target;
		if (!target || !is_comfy_upload(target.url, target.method, body)) {
			return native_send.call(this, body);
		}
		const request = this;
		const total = body.get('image').size;
		const on_fraction = (fraction) => request.upload.dispatchEvent(new ProgressEvent('progress', { lengthComputable: true, loaded: Math.round(fraction * total), total: total }));
		run_upload(target.url, body, on_fraction).then((result) => {
			if (result.unsupported) {
				native_send.call(request, body);
				return;
			}
			const answer = { readyState: 4, status: result.status, statusText: result.status === 200 ? 'OK' : 'Error', responseText: result.text, response: result.text };
			Object.keys(answer).forEach((name) => Object.defineProperty(request, name, { configurable: true, value: answer[name] }));
			[ 'readystatechange', 'load', 'loadend' ].forEach((type) => request.dispatchEvent(new ProgressEvent(type)));
		});
	};
})();
