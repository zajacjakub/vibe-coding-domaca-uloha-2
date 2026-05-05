#!/usr/bin/env node
// Node.js equivalent of check_links.ps1
// Checks links from articles.json and products.json, writes data/links.json and data/bad_links.json

'use strict';

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const root = path.resolve(__dirname, '..', '..');
const configPath = path.join(root, 'audit.config.json');
const productsPath = path.join(root, 'data', 'products.json');
const articlesPath = path.join(root, 'data', 'articles.json');
const linksPath = path.join(root, 'data', 'links.json');
const badLinksPath = path.join(root, 'data', 'bad_links.json');

// Strip UTF-8 BOM if present before parsing JSON
function readJson(filePath) {
  let raw = fs.readFileSync(filePath, 'utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  return JSON.parse(raw);
}

if (!fs.existsSync(configPath)) {
  console.error('Missing audit.config.json'); process.exit(1);
}
const config = readJson(configPath);
const shopUrl = config.shop.url.replace(/\/$/, '');
const cacheMaxAgeDays = (config.links && config.links.cache_max_age_days) ? config.links.cache_max_age_days : 7;
const whitelistDomains = (config.links && config.links.whitelist_domains)
  ? config.links.whitelist_domains.map(d => d.toLowerCase())
  : ['instagram.com','facebook.com','linkedin.com','twitter.com','x.com','tiktok.com','medium.com','t.co','bit.ly','goo.gl'];

const UA = 'Mozilla/5.0 (compatible; ContentAuditLinkChecker/1.0)';
const TIMEOUT_MS = 15000;

function isWhitelisted(urlStr) {
  try {
    const host = new URL(urlStr).hostname.toLowerCase();
    return whitelistDomains.some(w => host === w || host.endsWith('.' + w));
  } catch (_) { return false; }
}

function checkUrl(urlStr, method = 'HEAD', redirectCount = 0) {
  return new Promise((resolve) => {
    if (redirectCount > 5) return resolve({ status: null, error: 'too many redirects' });
    let parsed;
    try { parsed = new URL(urlStr); } catch (e) { return resolve({ status: null, error: e.message }); }
    const lib = parsed.protocol === 'https:' ? https : http;
    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
      path: parsed.pathname + parsed.search,
      method: method.toUpperCase(),
      headers: { 'User-Agent': UA },
      timeout: TIMEOUT_MS,
      rejectUnauthorized: false,
    };
    const req = lib.request(options, (res) => {
      // Drain body for GET requests
      res.resume();
      const code = res.statusCode;
      if ([301, 302, 303, 307, 308].includes(code) && res.headers.location) {
        const loc = res.headers.location.startsWith('http')
          ? res.headers.location
          : shopUrl + res.headers.location;
        return checkUrl(loc, method, redirectCount + 1).then(resolve);
      }
      resolve({ status: code, error: null });
    });
    req.on('error', (e) => resolve({ status: null, error: e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ status: null, error: 'timeout' }); });
    req.end();
  });
}

function extractLinks(bodyHtml, shopUrl) {
  const links = [];
  const re = /<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>/gi;
  let m;
  while ((m = re.exec(bodyHtml)) !== null) {
    let u = m[1].trim().replace(/&amp;/g, '&');
    if (/^(#|mailto:|tel:|javascript:)/i.test(u)) continue;
    if (u.startsWith('//')) u = 'https:' + u;
    if (u.startsWith('/')) u = shopUrl + u;
    if (!/^https?:\/\//i.test(u)) continue;
    links.push(u);
  }
  return links;
}

async function main() {
  const haveProducts = fs.existsSync(productsPath);
  const haveArticles = fs.existsSync(articlesPath);
  if (!haveProducts && !haveArticles) {
    console.error('No source snapshots found (data/products.json or data/articles.json).');
    process.exit(1);
  }

  const products = haveProducts ? readJson(productsPath) : [];
  const articles = haveArticles ? readJson(articlesPath) : [];
  console.log(`Sources: ${products.length} products, ${articles.length} articles`);

  // Load cache
  const cache = {};
  if (fs.existsSync(linksPath)) {
    try {
      const existing = readJson(linksPath);
      for (const l of existing) cache[l.url] = l;
      console.log(`Loaded ${Object.keys(cache).length} cached link results`);
    } catch (_) {
      console.warn('Could not parse existing links.json, starting with empty cache');
    }
  }

  // Build (url -> {products_using, articles_using}) mapping
  const urlToProducts = {};
  const urlToArticles = {};

  for (const p of products) {
    if (!p.body_html) continue;
    for (const u of extractLinks(p.body_html, shopUrl)) {
      if (!urlToProducts[u]) urlToProducts[u] = [];
      urlToProducts[u].push({ handle: p.handle, title: p.title });
    }
  }
  for (const a of articles) {
    if (!a.body_html) continue;
    for (const u of extractLinks(a.body_html, shopUrl)) {
      if (!urlToArticles[u]) urlToArticles[u] = [];
      urlToArticles[u].push({ handle: a.slug, title: a.title });
    }
  }

  const allUrls = Array.from(new Set([...Object.keys(urlToProducts), ...Object.keys(urlToArticles)])).sort();
  console.log(`Found ${allUrls.length} unique URLs to check`);

  const now = new Date();
  const results = [];

  for (const url of allUrls) {
    const cached = cache[url];
    let useCached = false;
    if (cached && cached.last_checked) {
      try {
        const age = (now - new Date(cached.last_checked)) / (1000 * 60 * 60 * 24);
        if (age < cacheMaxAgeDays) useCached = true;
      } catch (_) {}
    }

    const whitelisted = isWhitelisted(url);
    let status, errorMsg, checkedAt;

    if (useCached) {
      console.log(`[cache] ${url} -> ${cached.status}`);
      status = cached.status;
      errorMsg = cached.error;
      checkedAt = cached.last_checked;
    } else {
      console.log(`[check] ${url}`);
      // HEAD first
      let r = await checkUrl(url, 'HEAD');
      // Fallback to GET for servers that block HEAD
      if (r.status !== null && [400, 403, 405, 501].includes(r.status)) {
        r = await checkUrl(url, 'GET');
      }
      status = r.status;
      errorMsg = r.error;
      checkedAt = now.toISOString();
    }

    // Dedupe articles_using and products_using
    const productsUsing = urlToProducts[url]
      ? Object.values(urlToProducts[url].reduce((acc, x) => { acc[x.handle] = x; return acc; }, {}))
      : [];
    const articlesUsing = urlToArticles[url]
      ? Object.values(urlToArticles[url].reduce((acc, x) => { acc[x.handle] = x; return acc; }, {}))
      : [];

    results.push({ url, status, error: errorMsg, whitelisted, last_checked: checkedAt, products_using: productsUsing, articles_using: articlesUsing });
  }

  results.sort((a, b) => a.url.localeCompare(b.url));
  fs.writeFileSync(linksPath, JSON.stringify(results, null, 2), 'utf8');

  const bad = results.filter(r => !r.whitelisted && (
    (r.status !== null && r.status >= 400) ||
    (r.status === null && r.error)
  ));
  fs.writeFileSync(badLinksPath, JSON.stringify(bad, null, 2), 'utf8');

  const whitelistedCount = results.filter(r => r.whitelisted).length;
  console.log(`\nTotal unique links: ${results.length}`);
  console.log(`Whitelisted (skipped from bad): ${whitelistedCount}`);
  console.log(`Bad links (4xx/5xx/error, not whitelisted): ${bad.length}`);
  console.log(`Wrote: ${linksPath}`);
  console.log(`Wrote: ${badLinksPath}`);
}

main().catch(e => { console.error(e); process.exit(1); });
