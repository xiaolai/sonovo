enum SampleHTML {
    static let storyboard = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <style>
    :root {
        --bg: #f3f2ee;
        --card: #ffffff;
        --text: #1c1c1e;
        --muted: #6d6d72;
        --faint: #9a9a9f;
        --line: #dedcd5;
        --accent: #2f6f8f;
        --accent-soft: rgba(47, 111, 143, 0.10);
        --shadow: 0 1px 2px rgba(0,0,0,.05), 0 8px 24px rgba(0,0,0,.06);
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --bg: #1b1b1d;
            --card: #252528;
            --text: #f2f1ec;
            --muted: #a7a6ac;
            --faint: #7c7b82;
            --line: #3a3a3e;
            --accent: #7db6d1;
            --accent-soft: rgba(125, 182, 209, 0.12);
            --shadow: 0 1px 2px rgba(0,0,0,.3), 0 8px 24px rgba(0,0,0,.25);
        }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
        background: var(--bg);
        color: var(--text);
        font: 13px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        -webkit-font-smoothing: antialiased;
        padding: 30px 32px 36px;
    }
    .eyebrow {
        font-size: 9px;
        font-weight: 600;
        letter-spacing: 1.3px;
        color: var(--faint);
        text-transform: uppercase;
    }
    header {
        display: flex;
        align-items: flex-end;
        justify-content: space-between;
        gap: 20px;
        padding-bottom: 18px;
        border-bottom: 1px solid var(--line);
        margin-bottom: 22px;
    }
    h1 {
        margin: 5px 0 4px;
        font: 600 26px/1.15 "New York", ui-serif, Georgia, serif;
        letter-spacing: -0.3px;
    }
    .meta { color: var(--muted); font-size: 11px; }
    .badge {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 4px 9px;
        border-radius: 999px;
        background: var(--accent-soft);
        color: var(--accent);
        font-size: 9px;
        font-weight: 600;
        letter-spacing: .8px;
        white-space: nowrap;
    }
    .badge::before {
        content: "";
        width: 5px; height: 5px;
        border-radius: 50%;
        background: currentColor;
    }
    .grid {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 16px;
    }
    .scene {
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 10px;
        overflow: hidden;
        box-shadow: var(--shadow);
    }
    .thumb {
        position: relative;
        aspect-ratio: 16 / 9;
        background: linear-gradient(180deg, #2a3448 0%, #d98c6a 61%, #1f2a36 61%, #121a22 100%);
    }
    .thumb::before {
        content: "";
        position: absolute;
        left: 64%; top: 35%;
        width: 34px; height: 34px;
        border-radius: 50%;
        background: rgba(255, 220, 160, .9);
        box-shadow: 0 0 40px rgba(255, 200, 140, .55);
    }
    .thumb::after {
        content: "";
        position: absolute;
        left: 0; right: 0; top: 61%;
        height: 1px;
        background: rgba(255,255,255,.18);
    }
    .scene:nth-child(2) .thumb {
        background: linear-gradient(180deg, #7e8a96 0%, #c7c9c5 61%, #6f7d86 61%, #44525b 100%);
    }
    .scene:nth-child(2) .thumb::before { left: 30%; background: rgba(240,236,225,.8); }
    .scene:nth-child(3) .thumb {
        background: linear-gradient(180deg, #2a2f53 0%, #c06b71 61%, #343a59 61%, #181d2e 100%);
    }
    .scene:nth-child(3) .thumb::before { left: 55%; background: rgba(242,179,122,.9); }
    .scene:nth-child(4) .thumb {
        background: linear-gradient(180deg, #5b8fc7 0%, #cfe3ea 61%, #3f718c 61%, #234657 100%);
    }
    .scene:nth-child(4) .thumb::before { left: 76%; width: 24px; height: 24px; background: rgba(255,244,214,.95); }
    .scene:nth-child(5) .thumb {
        background: linear-gradient(180deg, #3b4a57 0%, #8fa2a8 61%, #334b56 61%, #1d2c33 100%);
    }
    .scene:nth-child(5) .thumb::before { left: 22%; width: 20px; height: 20px; background: rgba(216,210,194,.7); }
    .scene:nth-child(6) .thumb {
        background: linear-gradient(180deg, #412b2b 0%, #d8794d 61%, #3a2f33 61%, #1d181a 100%);
    }
    .scene:nth-child(6) .thumb::before { left: 42%; background: rgba(255,196,107,.95); }
    .scene-body { padding: 10px 12px 12px; }
    .scene-top {
        display: flex; align-items: baseline; justify-content: space-between;
        gap: 8px; margin-bottom: 2px;
    }
    .scene-number {
        font-size: 9px; font-weight: 600; letter-spacing: .9px;
        color: var(--faint);
    }
    .scene-time {
        font: 9px/1 ui-monospace, "SF Mono", Menlo, monospace;
        color: var(--faint);
    }
    .scene-title { font-size: 12px; font-weight: 600; }
    .scene-detail { margin-top: 2px; font-size: 10px; color: var(--muted); }
    footer {
        display: flex; justify-content: space-between; gap: 16px;
        margin-top: 22px; padding-top: 14px;
        border-top: 1px solid var(--line);
        color: var(--faint); font-size: 10px;
    }
    @media (max-width: 700px) {
        body { padding: 22px 18px 28px; }
        .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
        header { align-items: flex-start; flex-direction: column; }
    }
    @media (max-width: 460px) {
        .grid { grid-template-columns: 1fr; }
    }
    </style>
    </head>
    <body>
    <header>
        <div>
            <div class="eyebrow">Tidewater · Episode 01</div>
            <h1>The Harbor at Six</h1>
            <div class="meta">8 scenes · Review draft · Generated 2 min ago</div>
        </div>
        <span class="badge">REVIEW DRAFT</span>
    </header>

    <div class="grid">
        <article class="scene">
            <div class="thumb"></div>
            <div class="scene-body">
                <div class="scene-top"><span class="scene-number">SCENE 01</span><span class="scene-time">00:00</span></div>
                <div class="scene-title">Harbor at dawn</div>
                <div class="scene-detail">Wide · Fog over still water</div>
            </div>
        </article>
        <article class="scene">
            <div class="thumb"></div>
            <div class="scene-body">
                <div class="scene-top"><span class="scene-number">SCENE 02</span><span class="scene-time">00:02</span></div>
                <div class="scene-title">Fog on the water</div>
                <div class="scene-detail">Medium · Low horizon</div>
            </div>
        </article>
        <article class="scene">
            <div class="thumb"></div>
            <div class="scene-body">
                <div class="scene-top"><span class="scene-number">SCENE 03</span><span class="scene-time">00:05</span></div>
                <div class="scene-title">First boat</div>
                <div class="scene-detail">Wide · Skiff enters frame</div>
            </div>
        </article>
        <article class="scene">
            <div class="thumb"></div>
            <div class="scene-body">
                <div class="scene-top"><span class="scene-number">SCENE 04</span><span class="scene-time">00:07</span></div>
                <div class="scene-title">The town wakes</div>
                <div class="scene-detail">Detail · A light, a door</div>
            </div>
        </article>
        <article class="scene">
            <div class="thumb"></div>
            <div class="scene-body">
                <div class="scene-top"><span class="scene-number">SCENE 05</span><span class="scene-time">00:10</span></div>
                <div class="scene-title">Kettle</div>
                <div class="scene-detail">Insert · Steam in cold air</div>
            </div>
        </article>
        <article class="scene">
            <div class="thumb"></div>
            <div class="scene-body">
                <div class="scene-top"><span class="scene-number">SCENE 06</span><span class="scene-time">00:12</span></div>
                <div class="scene-title">Day begins</div>
                <div class="scene-detail">Wide · Return to harbor</div>
            </div>
        </article>
    </div>

    <footer>
        <span>Storyboard · 8 scenes · 2 open notes</span>
        <span>Local preview · No network</span>
    </footer>
    </body>
    </html>
    """
}
