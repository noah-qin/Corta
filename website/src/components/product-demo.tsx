// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

"use client";

import { useEffect, useRef, useState } from "react";

type Props = {
  src: string;
  poster: { src: string; srcSet: string; width: number; height: number };
  copy: { description: string; play: string; pause: string; open: string };
  overview: { href: string; label: string };
};

/** Only load motion while visible; a still remains available before hydration. */
export function ProductDemo({ src, poster, copy, overview }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const manualPause = useRef(false);
  const optedIn = useRef(false);
  const [enhanced, setEnhanced] = useState(false);
  const [playing, setPlaying] = useState(false);
  const [hasPlayed, setHasPlayed] = useState(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let visible = false;
    function reconcile() {
      if (!video) return;
      if (
        visible &&
        !document.hidden &&
        !manualPause.current &&
        (!motion.matches || optedIn.current)
      ) {
        if (!video.getAttribute("src")) video.src = src;
        void video.play().catch(() => {
          /* The explicit play button can retry. */
        });
      } else video.pause();
    }
    function preferenceChanged() {
      if (motion.matches) optedIn.current = false;
      reconcile();
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        reconcile();
      },
      { threshold: 0.2 },
    );
    observer.observe(video);
    motion.addEventListener("change", preferenceChanged);
    document.addEventListener("visibilitychange", reconcile);
    setEnhanced(true);
    return () => {
      observer.disconnect();
      motion.removeEventListener("change", preferenceChanged);
      document.removeEventListener("visibilitychange", reconcile);
      video.pause();
    };
  }, [src]);

  function toggle() {
    const video = videoRef.current;
    if (!video) return;
    // A pending play() already clears video.paused before onPlaying fires.
    // Follow the same state as the visible label so Play cannot cancel buffering.
    if (!playing) {
      manualPause.current = false;
      optedIn.current = true;
      if (!video.getAttribute("src")) video.src = src;
      void video.play().catch(() => {});
    } else {
      manualPause.current = true;
      video.pause();
    }
  }

  return (
    <figure className="product-shot wrap">
      <div className="demo-stage">
        <img
          src={poster.src}
          srcSet={poster.srcSet}
          sizes="(max-width: 800px) calc(100vw - 40px), (max-width: 1056px) calc(100vw - 96px), 960px"
          width={poster.width}
          height={poster.height}
          alt={copy.description}
          fetchPriority="high"
        />
        <video
          ref={videoRef}
          className={hasPlayed && !failed ? "is-playing" : undefined}
          width={poster.width}
          height={poster.height}
          poster={poster.src}
          aria-label={copy.description}
          muted
          loop
          playsInline
          preload="none"
          onPlaying={() => {
            setPlaying(true);
            setHasPlayed(true);
          }}
          onPause={() => setPlaying(false)}
          onError={() => {
            setFailed(true);
            setPlaying(false);
          }}
        >
          <a href={src}>{copy.open}</a>
        </video>
      </div>
      <figcaption>
        <span className="dot" />
        {copy.description}
        <button
          className="demo-toggle"
          type="button"
          onClick={toggle}
          disabled={!enhanced || failed}
          aria-pressed={playing}
        >
          <span aria-hidden="true">{playing ? "Ⅱ" : "▷"}</span>{" "}
          {playing ? copy.pause : copy.play}
        </button>
        {failed && <a href={src}>{copy.open}</a>}
        <noscript>
          <a href={src}>{copy.open}</a>
        </noscript>
        <a href={overview.href}>
          {overview.label} <span aria-hidden="true">→</span>
        </a>
      </figcaption>
    </figure>
  );
}
