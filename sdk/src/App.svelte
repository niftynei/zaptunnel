<script lang="ts">
  import {
    connect,
    DEFAULT_RELAY,
    diagnoseZaptunnelError,
    type ZaptunnelClient,
    type ZaptunnelTroubleshooting
  } from "./index";

  type State = "idle" | "connecting" | "calling" | "success" | "error";
  type GetInfo = {
    id?: string;
    alias?: string;
    color?: string;
    num_peers?: number;
    num_active_channels?: number;
    num_inactive_channels?: number;
    num_pending_channels?: number;
    blockheight?: number;
    network?: string;
    version?: string;
    [key: string]: unknown;
  };

  const runeCommand = `lightning-cli createrune -k "restrictions"='[["method=getinfo"]]'`;
  const nodeIdPattern = "(02|03)[0-9a-fA-F]{64}";
  const relayOrigin = import.meta.env.VITE_ZAPTUNNEL_RELAY ?? DEFAULT_RELAY;

  let nodeId = "";
  let address = "";
  let rune = "";
  let revealRune = false;
  let copied = false;
  let state: State = "idle";
  let result: GetInfo | null = null;
  let diagnostic: ZaptunnelTroubleshooting | null = null;
  let requestIdCopied = false;

  async function copyCommand() {
    await navigator.clipboard.writeText(runeCommand);
    copied = true;
    window.setTimeout(() => (copied = false), 1800);
  }

  async function runGetInfo() {
    state = "connecting";
    result = null;
    diagnostic = null;
    requestIdCopied = false;
    let client: ZaptunnelClient | undefined;

    try {
      client = await connect({
        relay: relayOrigin,
        nodeId: nodeId.trim(),
        address: address.trim(),
        rune: rune.trim(),
        reconnect: false
      });
      state = "calling";
      result = await client.getinfo<GetInfo>();
      state = "success";
    } catch (error) {
      diagnostic = diagnoseZaptunnelError(error);
      state = "error";
    } finally {
      client?.disconnect();
      rune = "";
      revealRune = false;
    }
  }

  async function copyRequestId() {
    if (!diagnostic?.requestId) return;
    await navigator.clipboard.writeText(diagnostic.requestId);
    requestIdCopied = true;
    window.setTimeout(() => (requestIdCopied = false), 1800);
  }
</script>

<svelte:head>
  <link rel="canonical" href="https://zapptunnel.com/" />
</svelte:head>

<header class="topbar">
  <a class="brand" href="#top" aria-label="Zaptunnel home">
    <span class="brand-mark" aria-hidden="true">ϟ</span>
    <span>ZAPTUNNEL</span>
  </a>
  <nav aria-label="Primary navigation">
    <a href="#demo">Live demo</a>
    <a href="#how-it-works">How it works</a>
    <a href="#sdk">SDK</a>
  </nav>
  <span class="alpha"><i></i> Public alpha</span>
</header>

<main id="top">
  <section class="hero">
    <div class="aurora aurora-cyan" aria-hidden="true"></div>
    <div class="aurora aurora-yellow" aria-hidden="true"></div>
    <div class="energy-field" aria-hidden="true">
      <span>ϟ</span><span>ϟ</span><span>ϟ</span><span>ϟ</span><span>ϟ</span>
      <span>ϟ</span><span>ϟ</span><span>ϟ</span><span>ϟ</span><span>ϟ</span>
    </div>
    <div class="eyebrow">Browser access for Core Lightning</div>
    <h1>Your node.<br /><em>From anywhere.</em></h1>
    <p class="lede">
      Give a web app a direct Lightning connection to your Core Lightning node—without opening a
      new port, managing a certificate, or letting the relay read your RPC traffic.
    </p>
    <div class="compatibility" aria-label="Core Lightning compatibility">
      <span>Built for</span>
      <a href="https://docs.corelightning.org/docs/home">Core Lightning</a>
      <i>·</i>
      <a href="https://github.com/lightning/bolts/blob/master/08-transport.md">BOLT 8</a>
      <i>·</i>
      <a href="https://docs.corelightning.org/reference/commando">Commando</a>
    </div>
    <div class="hero-actions">
      <a class="button primary" href="#demo">Try getinfo <span>↓</span></a>
      <a class="button secondary" href="#sdk">Read the SDK guide</a>
    </div>

    <div class="route" aria-label="Connection path">
      <div><span class="route-icon">⌘</span><strong>Your browser</strong><small>lnmessage</small></div>
      <span class="line"><i></i><small>BOLT-8 encrypted</small></span>
      <div class="relay"><span class="route-icon">ϟ</span><strong>Zaptunnel</strong><small>blind relay</small></div>
      <span class="line"><i></i><small>TCP</small></span>
      <div><span class="route-icon">●</span><strong>Your CLN node</strong><small>:9735</small></div>
    </div>
  </section>

  <div class="voltage-strip" aria-hidden="true">
    <div class="voltage-track">
      <div class="voltage-group">
        <span>END-TO-END ENCRYPTED</span><b>ϟ</b><span>LIGHTNING NATIVE</span><b>ϟ</b>
        <span>NO NODE AGENT</span><b>ϟ</b><span>BLIND RELAY</span><b>ϟ</b>
      </div>
      <div class="voltage-group">
        <span>END-TO-END ENCRYPTED</span><b>ϟ</b><span>LIGHTNING NATIVE</span><b>ϟ</b>
        <span>NO NODE AGENT</span><b>ϟ</b><span>BLIND RELAY</span><b>ϟ</b>
      </div>
    </div>
  </div>

  <section class="demo-section" id="demo">
    <div class="section-heading">
      <div><span class="section-number">01 / LIVE DEMO</span><h2>Ask your node who it is.</h2></div>
      <p>Create a narrowly scoped rune, then make a real <code>getinfo</code> call from this page.</p>
    </div>

    <div class="demo-grid">
      <aside class="instructions">
        <div class="step">
          <span>1</span>
          <div><h3>Find your node</h3><p>Copy the <code>id</code> from <code>lightning-cli getinfo</code> and provide the clearnet or v3 onion <code>host:port</code> where CLN listens.</p></div>
        </div>
        <div class="step">
          <span>2</span>
          <div>
            <h3>Create a getinfo-only rune</h3>
            <p>Run this on the CLN host. It authorizes exactly one RPC method and cannot pay, invoice, or change configuration.</p>
            <div class="command">
              <code>{runeCommand}</code>
              <button type="button" onclick={copyCommand} aria-label="Copy rune command">{copied ? "Copied" : "Copy"}</button>
            </div>
            <p class="hint">Use the <code>rune</code> value from the returned JSON—not the unique ID.</p>
          </div>
        </div>
        <div class="step">
          <span>3</span>
          <div><h3>Connect below</h3><p>The rune remains in memory for this request and is never stored by this page.</p></div>
        </div>
      </aside>

      <div class="console-card">
        <div class="console-title"><span><i></i><i></i><i></i></span><b>GETINFO CONSOLE</b><small class="console-host">relay.zapptunnel.com</small></div>
        <form onsubmit={(event) => { event.preventDefault(); runGetInfo(); }}>
          <label for="node-id">Node ID <small>66-character compressed public key</small></label>
          <input id="node-id" bind:value={nodeId} placeholder="02abc…" pattern={nodeIdPattern} minlength="66" maxlength="66" required autocomplete="off" spellcheck="false" />

          <label for="address">Lightning address <small>clearnet or v3 onion host and peer port</small></label>
          <input id="address" bind:value={address} placeholder="node.example.com:9735 or ….onion:9735" required autocomplete="off" spellcheck="false" />

          <label for="rune">Getinfo rune <small>encrypted end to end</small></label>
          <div class="rune-field">
            <input id="rune" type={revealRune ? "text" : "password"} bind:value={rune} placeholder="Paste the rune value" required autocomplete="off" spellcheck="false" />
            <button type="button" onclick={() => (revealRune = !revealRune)}>{revealRune ? "Hide" : "Show"}</button>
          </div>

          <button class="connect-button" type="submit" disabled={state === "connecting" || state === "calling"}>
            {#if state === "connecting"}Establishing BOLT-8…{:else if state === "calling"}Calling getinfo…{:else}Connect + run getinfo <span>→</span>{/if}
          </button>
        </form>

        <div class:success={state === "success"} class:error={state === "error"} class="result" aria-live="polite" data-testid="status">
          {#if state === "idle"}
            <div class="empty-result"><span>ϟ</span><p>Your node information will appear here.</p></div>
          {:else if state === "connecting" || state === "calling"}
            <div class="working"><i></i><p>{state === "connecting" ? "Negotiating an encrypted peer session…" : "Commando request sent. Waiting for CLN…"}</p></div>
          {:else if state === "error" && diagnostic}
            <div class="diagnostic">
              <strong>{diagnostic.title}</strong>
              <p>{diagnostic.summary}</p>
              <div class="diagnostic-meta">
                <span>{diagnostic.stage.replaceAll("_", " ")}</span>
                <code>{diagnostic.causeCode ?? diagnostic.code}</code>
              </div>
              <ul class="suggestions">
                {#each diagnostic.suggestions as suggestion}
                  <li>{suggestion}</li>
                {/each}
              </ul>
              {#if diagnostic.requestId}
                <div class="request-id">
                  <span><small>Relay request ID</small><code>{diagnostic.requestId}</code></span>
                  <button type="button" onclick={copyRequestId}>{requestIdCopied ? "Copied" : "Copy"}</button>
                </div>
              {/if}
              <div class="diagnostic-actions">
                <button type="button" onclick={runGetInfo}>Try connection again</button>
              </div>
            </div>
          {:else if result}
            <div class="node-summary">
              <div class="node-color" style:background={result.color ? `#${result.color}` : "#f5b942"}></div>
              <div><small>CONNECTED NODE</small><h3>{result.alias ?? "Unnamed node"}</h3><code>{result.id ?? nodeId}</code></div>
            </div>
            <dl>
              <div><dt>Network</dt><dd>{result.network ?? "—"}</dd></div>
              <div><dt>Version</dt><dd>{result.version ?? "—"}</dd></div>
              <div><dt>Block height</dt><dd>{result.blockheight?.toLocaleString() ?? "—"}</dd></div>
              <div><dt>Peers</dt><dd>{result.num_peers ?? "—"}</dd></div>
              <div><dt>Active channels</dt><dd>{result.num_active_channels ?? "—"}</dd></div>
              <div><dt>Pending channels</dt><dd>{result.num_pending_channels ?? "—"}</dd></div>
            </dl>
            <details><summary>Raw getinfo response</summary><pre>{JSON.stringify(result, null, 2)}</pre></details>
          {/if}
        </div>
        <p class="privacy"><span>◆</span> This page can see what you enter, but does not log or persist it. Use only the getinfo-only rune above.</p>
      </div>
    </div>
  </section>

  <section class="principles" id="how-it-works">
    <article><b>01</b><h2>Lightning-native</h2><p>The browser makes an ordinary BOLT-8 peer connection. Zaptunnel only carries its encrypted bytes.</p></article>
    <article><b>02</b><h2>Relay stays blind</h2><p>Your rune and RPC payload are encrypted to the node key. The relay can route them, never read them.</p></article>
    <article><b>03</b><h2>No node agent</h2><p>Point the SDK at the clearnet or v3 onion Lightning address your node already accepts. Nothing extra runs beside CLN.</p></article>
  </section>

  <section class="sdk-section" id="sdk">
    <div class="section-heading">
      <div><span class="section-number">02 / BUILD WITH IT</span><h2>Three fields. One resilient connection.</h2></div>
      <p>The same SDK powers the demo above. Its connection manager recovers from relay restarts, network changes, and mobile browser suspension.</p>
    </div>
    <div class="code-window">
      <div class="code-tabs"><span>TypeScript</span><small>@zaptunnel/sdk</small></div>
      <pre><code><span class="keyword">import</span> {'{ createConnectionManager }'} <span class="keyword">from</span> <span class="green">"@zaptunnel/sdk"</span>;

<span class="keyword">const</span> node = createConnectionManager({'{'}
  nodeId: <span class="green">"02abc…"</span>,
  address: <span class="green">"node.example.com:9735"</span>,
  rune: getinfoRune
{'}'});

<span class="keyword">await</span> node.start();
<span class="keyword">const</span> info = <span class="keyword">await</span> node.getinfo();</code></pre>
    </div>
    <div class="sdk-resources" aria-label="SDK documentation links">
      <div>
        <span>PAYMENT EVENTS</span>
        <h3>Listen for paid invoices</h3>
        <p><code>paidInvoices()</code> is an async iterator backed by CLN’s resumable <code>waitanyinvoice</code> RPC.</p>
        <pre><code><span class="keyword">for await</span> (<span class="keyword">const</span> invoice <span class="keyword">of</span> node.paidInvoices()) {'{'}
  console.log(invoice.pay_index);
{'}'}</code></pre>
      </div>
      <div>
        <span>REFERENCE</span>
        <h3>Go beyond getinfo</h3>
        <p><code>node.call(method, params)</code> reaches any Commando-accessible RPC exposed by your node.</p>
        <nav aria-label="Developer references">
          <a href="https://www.npmjs.com/package/@zaptunnel/sdk">npm package <b>↗</b></a>
          <a href="https://github.com/niftynei/zaptunnel/tree/main/sdk">Full SDK guide <b>↗</b></a>
          <a href="https://docs.corelightning.org/reference/">CLN RPC reference <b>↗</b></a>
          <a href="https://docs.corelightning.org/reference/createrune">Rune reference <b>↗</b></a>
        </nav>
      </div>
    </div>
  </section>
</main>

<footer>
  <a class="brand" href="#top"><span class="brand-mark">ϟ</span><span>ZAPTUNNEL</span></a>
  <div class="footer-copy">
    <p>End-to-end encrypted Lightning access for the open web.</p>
    <small>
      <a href="https://docs.corelightning.org/docs/home">Core Lightning</a> is
      <a href="https://blockstream.com/lightning/">Blockstream’s</a> open-source Lightning
      implementation. Zaptunnel is an independent project and is not affiliated with or endorsed
      by Blockstream.
    </small>
  </div>
</footer>
