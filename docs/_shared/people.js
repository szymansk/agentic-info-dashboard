// people.js — Top-20 der Agentic-AI-Szene
// Zentrale Datenquelle für /whoiswho/ und Hover-Tooltips auf allen Dashboards.

const PEOPLE = [
  {
    slug: "dario-amodei",
    name: "Dario Amodei",
    role: "CEO & Co-Founder",
    affiliation: "Anthropic",
    categories: ["lab", "safety"],
    expertise: ["Constitutional AI", "Scaling Laws", "RLHF"],
    background: "Physik-PhD Princeton, ex-Google Brain, ex-VP Research bei OpenAI. Mit Schwester Daniela 2021 Anthropic gegründet.",
    why: "Architekt des Constitutional-AI-Ansatzes. Sein Manifest „Machines of Loving Grace” prägt 2026 den Safety-First-Diskurs der Branche.",
    links: [
      { label: "Anthropic", url: "https://www.anthropic.com/" },
      { label: "Essay", url: "https://www.darioamodei.com/" }
    ],
    color: "#c39a4a"
  },
  {
    slug: "andrej-karpathy",
    name: "Andrej Karpathy",
    role: "Researcher (neu)",
    affiliation: "Anthropic",
    categories: ["researcher", "engineer"],
    expertise: ["Neural Architectures", "Education", "End-to-End ML"],
    background: "Stanford-PhD bei Fei-Fei Li, OpenAI-Gründungsmitglied, ex-Director of AI bei Tesla (Autopilot), Gründer Eureka Labs. Mai 2026 zu Anthropic.",
    why: "Wahrscheinlich der einflussreichste AI-Educator weltweit (YouTube „Zero-to-Hero”). Verkörpert das End-to-End-Engineer-Ideal: vom Backprop bis zur Produktauslieferung.",
    links: [
      { label: "Karpathy.ai", url: "https://karpathy.ai/" },
      { label: "X / @karpathy", url: "https://x.com/karpathy" }
    ],
    color: "#7aa2f7"
  },
  {
    slug: "ilya-sutskever",
    name: "Ilya Sutskever",
    role: "Co-Founder & CEO",
    affiliation: "Safe Superintelligence (SSI)",
    categories: ["researcher", "lab", "safety"],
    expertise: ["Deep Learning Fundamentals", "Scaling", "Alignment"],
    background: "Hinton-Schüler, Co-Autor AlexNet (2012), OpenAI-Gründungsmitglied & ex-Chief Scientist. 2024 SSI gegründet.",
    why: "Einer der wenigen, die seit 2012 an jedem Frontier-Sprung mitgeschrieben haben. SSI ist die schweigsamste, aber bestkapitalisierte „AGI-Wette” im Markt.",
    links: [
      { label: "SSI", url: "https://ssi.inc/" }
    ],
    color: "#b04bd1"
  },
  {
    slug: "demis-hassabis",
    name: "Demis Hassabis",
    role: "CEO",
    affiliation: "Google DeepMind",
    categories: ["lab", "researcher"],
    expertise: ["RL", "Search", "Protein Folding"],
    background: "Schach-Wunderkind, Cognitive-Science-PhD UCL, 2010 DeepMind mitgegründet. Nobelpreis Chemie 2024 (AlphaFold).",
    why: "Einziger Lab-Leader mit Nobelpreis. Lenkt Googles AI-Strategie zwischen Grundlagenforschung (AlphaFold, AlphaProof) und Produktivierung (Gemini, Spark).",
    links: [
      { label: "DeepMind", url: "https://deepmind.google/" }
    ],
    color: "#6ec38b"
  },
  {
    slug: "jeff-dean",
    name: "Jeff Dean",
    role: "Chief Scientist",
    affiliation: "Google",
    categories: ["engineer", "researcher"],
    expertise: ["Distributed Systems", "TensorFlow", "Pathways"],
    background: "Co-Autor MapReduce, Bigtable, Spanner, TensorFlow, Pathways. Senior Fellow Google seit 1999.",
    why: "Wer in den letzten 20 Jahren Google-Infrastruktur entwarf, bestimmt heute das Training-Stack der größten Modelle. Pathways war das Vorbild für Multi-Datacenter-Training.",
    links: [
      { label: "Jeff Dean", url: "https://research.google/people/jeff/" }
    ],
    color: "#6ec38b"
  },
  {
    slug: "yann-lecun",
    name: "Yann LeCun",
    role: "Chief AI Scientist",
    affiliation: "Meta · NYU",
    categories: ["researcher"],
    expertise: ["CNNs", "Self-Supervised Learning", "JEPA"],
    background: "Turing Award 2018 (mit Hinton + Bengio). CNN-Erfinder. NYU-Professor. Leitet FAIR seit 2013.",
    why: "Lautester Skeptiker der „LLM = AGI”-These. Pusht JEPA / World Models als Alternative. Wichtigste konträre Stimme im Mainstream — und Treiber von Llama-Open-Weights.",
    links: [
      { label: "Meta AI", url: "https://ai.meta.com/" },
      { label: "X / @ylecun", url: "https://x.com/ylecun" }
    ],
    color: "#7aa2f7"
  },
  {
    slug: "geoffrey-hinton",
    name: "Geoffrey Hinton",
    role: "Independent",
    affiliation: "ex-Google · U Toronto",
    categories: ["researcher", "safety"],
    expertise: ["Backprop", "Boltzmann Machines", "AI Risk"],
    background: "„Godfather of Deep Learning”. Turing Award 2018. Backprop-Mit-Erfinder, AlexNet-Co-Autor. 2023 Google verlassen, seitdem öffentlich Safety-Aktivist.",
    why: "Moralische Autorität des Felds. Seine Warnungen zu Existential Risk werden auch ernst genommen, weil er den Stack mit aufgebaut hat. Nobelpreis Physik 2024.",
    links: [
      { label: "U Toronto", url: "https://www.cs.toronto.edu/~hinton/" }
    ],
    color: "#e15a5a"
  },
  {
    slug: "yoshua-bengio",
    name: "Yoshua Bengio",
    role: "Scientific Director",
    affiliation: "Mila · U Montréal",
    categories: ["researcher", "safety"],
    expertise: ["Deep Learning Theory", "Governance"],
    background: "Turing Award 2018. Mila-Gründer. Université de Montréal.",
    why: "Akademischer Anker des Feldes. Treibt internationale Safety-Governance (UN-Beirat). Standortbestimmend für „verantwortungsvolle KI”.",
    links: [
      { label: "Mila", url: "https://mila.quebec/" }
    ],
    color: "#e15a5a"
  },
  {
    slug: "noam-shazeer",
    name: "Noam Shazeer",
    role: "Co-Lead Gemini",
    affiliation: "Google",
    categories: ["researcher", "engineer"],
    expertise: ["Transformer Architecture", "MoE", "Multi-Query Attention"],
    background: "Co-Autor „Attention Is All You Need” (2017). MoE, Multi-Query-Attention, Mixture-of-Experts. Gründer Character.ai, 2024 zurück zu Google.",
    why: "Vermutlich der einflussreichste ML-Architekt der LLM-Ära. Seine Ideen stecken in jedem Frontier-Modell.",
    links: [
      { label: "Paper", url: "https://arxiv.org/abs/1706.03762" }
    ],
    color: "#6ec38b"
  },
  {
    slug: "aidan-gomez",
    name: "Aidan Gomez",
    role: "Co-Founder & CEO",
    affiliation: "Cohere",
    categories: ["lab", "researcher"],
    expertise: ["LLMs", "Enterprise NLP"],
    background: "Co-Autor „Attention Is All You Need” als Praktikant. Toronto-PhD. 2019 Cohere gegründet.",
    why: "Hat den seltenen Weg „aus Forschung in Enterprise-Aufbau” konsequent gegangen. Cohere positioniert sich als enterprise-souveräne Alternative im regulierten Mittelbau.",
    links: [
      { label: "Cohere", url: "https://cohere.com/" }
    ],
    color: "#7aa2f7"
  },
  {
    slug: "arthur-mensch",
    name: "Arthur Mensch",
    role: "Co-Founder & CEO",
    affiliation: "Mistral AI",
    categories: ["lab", "researcher", "eu"],
    expertise: ["LLMs", "Open-Weight Models", "Scaling Laws"],
    background: "Ex-DeepMind (Chinchilla-Co-Autor). 2023 Mistral gegründet, in 12 Monaten zur EU-Vorzeige-Lab.",
    why: "Macht europäische KI international relevant. Open-Weight-Strategie als bewusste Differenzierung zu US-Closed-Labs.",
    links: [
      { label: "Mistral", url: "https://mistral.ai/" }
    ],
    color: "#c39a4a"
  },
  {
    slug: "mira-murati",
    name: "Mira Murati",
    role: "Founder",
    affiliation: "Thinking Machines Lab",
    categories: ["lab"],
    expertise: ["Multimodal Models", "Product"],
    background: "Maschinenbau, Tesla Model X, ex-CTO OpenAI (2022–2024). 2024 TML gegründet, in 6 Monaten ~$2 Mrd. Bewertung.",
    why: "Mit ihr ist ein erheblicher Teil des OpenAI-Talents abgewandert. TML ist die spannendste Stealth-Wette im Lab-Markt.",
    links: [
      { label: "TML", url: "https://thinkingmachines.ai/" }
    ],
    color: "#b04bd1"
  },
  {
    slug: "greg-brockman",
    name: "Greg Brockman",
    role: "Co-Founder & President",
    affiliation: "OpenAI",
    categories: ["engineer", "lab"],
    expertise: ["Systems Engineering", "Production ML"],
    background: "Ex-CTO Stripe, Co-Gründer OpenAI 2015. Engineering-Lead.",
    why: "Bleibt der seltene Senior, der noch tatsächlich Code commited. Verkörpert OpenAIs „Move Fast”-Kultur — und hält sie nach mehreren Talente-Wellen zusammen.",
    links: [
      { label: "OpenAI", url: "https://openai.com/" }
    ],
    color: "#6ec38b"
  },
  {
    slug: "john-schulman",
    name: "John Schulman",
    role: "Researcher",
    affiliation: "Anthropic",
    categories: ["researcher", "safety"],
    expertise: ["Reinforcement Learning", "PPO", "RLHF"],
    background: "Co-Gründer OpenAI, Erfinder PPO. August 2024 zu Anthropic gewechselt.",
    why: "Zentraler Architekt von RLHF, das ChatGPT erst möglich gemacht hat. Seine Wechsel-Begründung („Alignment-Arbeit gefährdet”) war ein Wendepunkt im Labs-Talent-Markt.",
    links: [
      { label: "Joschu.net", url: "https://joschu.net/" }
    ],
    color: "#e15a5a"
  },
  {
    slug: "jan-leike",
    name: "Jan Leike",
    role: "Researcher",
    affiliation: "Anthropic",
    categories: ["researcher", "safety"],
    expertise: ["Alignment", "Scalable Oversight"],
    background: "DeepMind, dann ex-Co-Lead OpenAI Superalignment. Mai 2024 zu Anthropic gewechselt.",
    why: "Mit Schulman zusammen das Signal, dass OpenAI Alignment-Talent verliert. Treibt jetzt Anthropics Safety-Forschung — Scalable Oversight ist sein Steckenpferd.",
    links: [
      { label: "Substack", url: "https://aligned.substack.com/" }
    ],
    color: "#e15a5a"
  },
  {
    slug: "fei-fei-li",
    name: "Fei-Fei Li",
    role: "Founder · Co-Director Stanford HAI",
    affiliation: "World Labs · Stanford",
    categories: ["researcher", "lab"],
    expertise: ["Computer Vision", "Spatial Intelligence"],
    background: "Stanford-Professorin, ImageNet-Erfinderin, Co-Director Stanford HAI. 2024 World Labs gegründet (Spatial Intelligence).",
    why: "ImageNet hat das ganze Deep-Learning-Boom-Jahrzehnt erst losgetreten. World Labs versucht, das gleiche für 3D-Verständnis zu tun — Konkurrenz zu Googles Omni.",
    links: [
      { label: "World Labs", url: "https://www.worldlabs.ai/" },
      { label: "Stanford HAI", url: "https://hai.stanford.edu/" }
    ],
    color: "#7aa2f7"
  },
  {
    slug: "chris-lattner",
    name: "Chris Lattner",
    role: "Co-Founder & CEO",
    affiliation: "Modular",
    categories: ["engineer"],
    expertise: ["Compilers", "LLVM", "MLIR", "Mojo"],
    background: "LLVM, Clang, Swift, MLIR — alles seine Geistesprodukte. Ex-Apple, ex-Tesla, ex-Google.",
    why: "Wahrscheinlich der einflussreichste Compiler-Engineer aller Zeiten. Modulars Mojo will Python-Performance um Größenordnungen heben — was AI-Inferenz neu definieren würde.",
    links: [
      { label: "Modular", url: "https://www.modular.com/" }
    ],
    color: "#c39a4a"
  },
  {
    slug: "francois-chollet",
    name: "François Chollet",
    role: "Co-Founder",
    affiliation: "Ndea",
    categories: ["researcher", "engineer"],
    expertise: ["Keras", "Generalization", "ARC Challenge"],
    background: "Keras-Erfinder, ex-Google. ARC-Challenge-Co-Designer (Test für „echte” Generalisierung). 2024 Ndea gegründet.",
    why: "Lautester Verfechter der These „LLMs lernen nicht wirklich neue Probleme”. ARC ist der ehrlichste Benchmark, den Frontier-Labs noch nicht geknackt haben.",
    links: [
      { label: "Ndea", url: "https://ndea.com/" },
      { label: "X / @fchollet", url: "https://x.com/fchollet" }
    ],
    color: "#7aa2f7"
  },
  {
    slug: "jonas-andrulis",
    name: "Jonas Andrulis",
    role: "Founder & CEO",
    affiliation: "Aleph Alpha",
    categories: ["lab", "eu", "dach"],
    expertise: ["Sovereign AI", "Enterprise LLMs"],
    background: "Ex-Apple Research, deutscher Quantum-/AI-Hintergrund. 2019 Aleph Alpha gegründet.",
    why: "Wichtigste DACH-Stimme im souveränen-KI-Diskurs. Aleph Alpha ist die einzige deutsche Antwort, die Enterprise-Verträge mit Bundes- und Landesstellen vorweisen kann.",
    links: [
      { label: "Aleph Alpha", url: "https://aleph-alpha.com/" }
    ],
    color: "#c39a4a"
  },
  {
    slug: "aravind-srinivas",
    name: "Aravind Srinivas",
    role: "Co-Founder & CEO",
    affiliation: "Perplexity",
    categories: ["lab", "researcher"],
    expertise: ["Retrieval-Augmented Generation", "Search"],
    background: "Berkeley-PhD, OpenAI-/DeepMind-Praktika. 2022 Perplexity gegründet.",
    why: "Hat „answer engine” als Produktkategorie gegen Googles Suche etabliert. Forschungs-getriebener CEO, der Produkt-Roadmap eng mit Modell-Qualität verzahnt.",
    links: [
      { label: "Perplexity", url: "https://www.perplexity.ai/" }
    ],
    color: "#7aa2f7"
  }
];

const PEOPLE_BY_SLUG = Object.fromEntries(PEOPLE.map(p => [p.slug, p]));

// Expose globally for the Who Is Who page renderer.
window.PEOPLE = PEOPLE;
window.PEOPLE_BY_SLUG = PEOPLE_BY_SLUG;

// ──────────────────────────────────────────────────────────────
// Inject minimal CSS for mentions + tooltips (self-contained).
// ──────────────────────────────────────────────────────────────
function injectStyles() {
  if (document.getElementById('person-tooltip-styles')) return;
  const style = document.createElement('style');
  style.id = 'person-tooltip-styles';
  style.textContent = `
    .person-mention {
      border-bottom: 1px dotted rgba(195,154,74,.55);
      cursor: help;
      transition: color .12s ease, border-color .12s ease;
    }
    .person-mention:hover { color: var(--accent, #c39a4a); border-bottom-color: var(--accent, #c39a4a); }
    .person-tooltip {
      position: fixed; z-index: 9999;
      width: 320px; max-width: calc(100vw - 24px);
      padding: 14px 16px;
      background: linear-gradient(180deg, #1b2030 0%, #161a24 100%);
      border: 1px solid #2d3447;
      border-radius: 12px;
      box-shadow: 0 18px 40px rgba(0,0,0,.55), 0 0 0 1px rgba(255,255,255,.02) inset;
      color: #e7ecf3;
      font-size: 13px; line-height: 1.5;
      opacity: 0; transform: translateY(4px);
      pointer-events: none;
      transition: opacity .14s ease, transform .14s ease;
    }
    .person-tooltip.visible { opacity: 1; transform: translateY(0); pointer-events: auto; }
    .person-tooltip .pt-head { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
    .person-tooltip .pt-avatar {
      width: 38px; height: 38px; border-radius: 50%;
      display: flex; align-items: center; justify-content: center;
      font-weight: 700; font-size: 14px; color: #0b0d12;
      flex-shrink: 0;
    }
    .person-tooltip .pt-name { font-weight: 700; font-size: 15px; letter-spacing: -.005em; }
    .person-tooltip .pt-role { color: #8b94a8; font-size: 12px; margin-top: 1px; }
    .person-tooltip .pt-tags { display: flex; flex-wrap: wrap; gap: 4px; margin: 8px 0; }
    .person-tooltip .pt-tag {
      font-size: 10.5px; padding: 1px 7px; border-radius: 999px;
      background: rgba(255,255,255,.05); border: 1px solid #2d3447;
      color: #b8c0d0; letter-spacing: .02em;
    }
    .person-tooltip .pt-why { color: #d8dce6; font-size: 12.5px; margin-bottom: 8px; }
    .person-tooltip .pt-foot {
      display: flex; justify-content: space-between; align-items: center;
      padding-top: 8px; border-top: 1px solid #232a3a;
      font-size: 11px; color: #8b94a8;
    }
    .person-tooltip .pt-foot a {
      color: #7aa2f7; text-decoration: none; font-weight: 600;
    }
    .person-tooltip .pt-foot a:hover { text-decoration: underline; }
  `;
  document.head.appendChild(style);
}

// ──────────────────────────────────────────────────────────────
// Build & position the singleton tooltip.
// ──────────────────────────────────────────────────────────────
function initPersonTooltips() {
  injectStyles();

  let tip = document.getElementById('person-tooltip');
  if (!tip) {
    tip = document.createElement('div');
    tip.id = 'person-tooltip';
    tip.className = 'person-tooltip';
    document.body.appendChild(tip);
  }

  let hideTimer = null;

  function buildTooltipHTML(p) {
    const initials = p.name.split(' ').map(s => s[0]).slice(0, 2).join('');
    const tagsHTML = (p.expertise || []).slice(0, 4)
      .map(t => `<span class="pt-tag">${t}</span>`).join('');
    return `
      <div class="pt-head">
        <div class="pt-avatar" style="background:${p.color}">${initials}</div>
        <div>
          <div class="pt-name">${p.name}</div>
          <div class="pt-role">${p.role} · ${p.affiliation}</div>
        </div>
      </div>
      <div class="pt-tags">${tagsHTML}</div>
      <div class="pt-why">${p.why}</div>
      <div class="pt-foot">
        <span>${p.background.split('.')[0]}.</span>
        <a href="/whoiswho/#${p.slug}">Profil →</a>
      </div>
    `;
  }

  function position(target) {
    const rect = target.getBoundingClientRect();
    const tw = tip.offsetWidth, th = tip.offsetHeight;
    let x = rect.left + rect.width / 2 - tw / 2;
    let y = rect.bottom + 8;
    // Clamp to viewport
    x = Math.max(8, Math.min(x, window.innerWidth - tw - 8));
    if (y + th > window.innerHeight - 8) {
      y = rect.top - th - 8;
    }
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }

  function show(el) {
    clearTimeout(hideTimer);
    const slug = el.dataset.person;
    const p = PEOPLE_BY_SLUG[slug];
    if (!p) return;
    tip.innerHTML = buildTooltipHTML(p);
    // Render once to measure, then position.
    tip.classList.add('visible');
    position(el);
    el._lastHover = el;
  }

  function scheduleHide() {
    hideTimer = setTimeout(() => tip.classList.remove('visible'), 180);
  }

  // Keep tooltip visible when cursor moves into it.
  tip.addEventListener('mouseenter', () => clearTimeout(hideTimer));
  tip.addEventListener('mouseleave', scheduleHide);

  document.querySelectorAll('[data-person]').forEach(el => {
    if (!PEOPLE_BY_SLUG[el.dataset.person]) return;
    el.classList.add('person-mention');
    el.addEventListener('mouseenter', () => show(el));
    el.addEventListener('mouseleave', scheduleHide);
    el.addEventListener('focus', () => show(el));
    el.addEventListener('blur', scheduleHide);
  });
}

// ──────────────────────────────────────────────────────────────
// Render the WhoisWho grid (only on /whoiswho/ page).
// ──────────────────────────────────────────────────────────────
function renderWhoIsWhoGrid() {
  const root = document.getElementById('people-grid');
  if (!root) return;

  const filterRoot = document.getElementById('people-filters');
  let activeFilter = 'all';

  function cardHTML(p) {
    const initials = p.name.split(' ').map(s => s[0]).slice(0, 2).join('');
    const tagsHTML = (p.expertise || [])
      .map(t => `<span class="ww-tag">${t}</span>`).join('');
    const linksHTML = (p.links || [])
      .map(l => `<a href="${l.url}" target="_blank" rel="noopener">${l.label} →</a>`).join('');
    const catBadges = (p.categories || [])
      .map(c => `<span class="ww-badge ww-cat-${c}">${CATEGORY_LABELS[c] || c}</span>`).join('');
    return `
      <article class="ww-card" id="${p.slug}" data-categories="${(p.categories||[]).join(' ')}">
        <header class="ww-head">
          <div class="ww-avatar" style="background:${p.color}">${initials}</div>
          <div class="ww-id">
            <h3>${p.name}</h3>
            <div class="ww-role">${p.role}</div>
            <div class="ww-affil">${p.affiliation}</div>
          </div>
        </header>
        <div class="ww-cats">${catBadges}</div>
        <div class="ww-tags">${tagsHTML}</div>
        <p class="ww-back"><strong>Werdegang:</strong> ${p.background}</p>
        <p class="ww-why"><strong>Warum wichtig:</strong> ${p.why}</p>
        <div class="ww-links">${linksHTML}</div>
      </article>`;
  }

  function render() {
    const filtered = activeFilter === 'all'
      ? PEOPLE
      : PEOPLE.filter(p => (p.categories || []).includes(activeFilter));
    root.innerHTML = filtered.map(cardHTML).join('');
  }

  if (filterRoot) {
    filterRoot.addEventListener('click', e => {
      const btn = e.target.closest('[data-filter]');
      if (!btn) return;
      activeFilter = btn.dataset.filter;
      filterRoot.querySelectorAll('[data-filter]').forEach(b =>
        b.classList.toggle('active', b === btn));
      render();
    });
  }

  render();

  // Scroll to hash on initial load (e.g. /whoiswho/#andrej-karpathy)
  if (location.hash) {
    const target = document.querySelector(location.hash);
    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
}

const CATEGORY_LABELS = {
  lab: "Lab-Leader",
  researcher: "Forscher",
  engineer: "Engineer",
  safety: "Safety / Alignment",
  eu: "EU",
  dach: "DACH"
};

document.addEventListener('DOMContentLoaded', () => {
  renderWhoIsWhoGrid();
  initPersonTooltips();
});
