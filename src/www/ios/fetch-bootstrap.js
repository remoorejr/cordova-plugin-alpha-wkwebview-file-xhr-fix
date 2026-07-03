"use strict";

(function () {
	// Guard against double-execution (document-start user script + Cordova js-module).  Without this,
	// a second run would set window.fetch = undefined AFTER the polyfill installed, breaking fetch.
	if (window.__alphaFetchBootstrapped) {
		return;
	}
	window.__alphaFetchBootstrapped = true;

	var _fetch = window.fetch;
	window.fetch = undefined;
})();
