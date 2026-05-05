#!/usr/bin/env node
// Node.js equivalent of fetch_articles.ps1
// Fetches blog articles from Shopify sitemap and writes data/articles.json

'use strict';

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const root = path.resolve(__dirname, '..', '..');
const configPath = path.join(root, 'audit.config.json');

if (!fs.existsSync(configPath)) {
  console.error('Missing audit.config.json');
  process.exit(1);
}

const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
if (!config.shop || !config.shop.url) {
  console.error('audit.config.json is missing shop.url');
  process.exit(1);
}

const shopUrl = config.shop.url.replace(/\/$/, '');
const UA = 'Mozilla/5.0 (compatible; ContentAuditFetcher/1.0)';

function fetchUrl(urlStr, method = 'GET', timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    let parsed;
    try { parsed = new URL(urlStr); } catch (e) { return reject(e); }
    const lib = parsed.protocol === 'https:' ? https : http;
    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
      path: parsed.pathname + parsed.search,
      method: method.toUpperCase(),
      headers: { 'User-Agent': UA },
      timeout: timeoutMs,
      rejectUnauthorized: false,
    };
    const req = lib.request(options, (res) => {
      // Follow redirects up to 5
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        const redirectUrl = res.headers.location.startsWith('http')
          ? res.headers.location
          : shopUrl + res.headers.location;
        return fetchUrl(redirectUrl, method, timeoutMs).then(resolve).catch(reject);
      }
      let data = '';
      res.setEncoding('utf8');
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve({ statusCode: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    req.end();
  });
}

function extractFirst(html, regex) {
  const m = html.match(regex);
  return m ? m[1] : '';
}

function extractImages(bodyHtml) {
  const images = [];
  const imgRe = /<img\b[^>]*>/gi;
  let imgMatch;
  while ((imgMatch = imgRe.exec(bodyHtml)) !== null) {
    const tag = imgMatch[0];
    const srcM = tag.match(/src\s*=\s*["']([^"']+)["']/i);
    const altM = tag.match(/alt\s*=\s*["']([^"']*)["']/i);
    if (srcM) {
      images.push({ src: srcM[1], alt: altM ? altM[1] : '' });
    }
  }
  return images;
}

function parseArticleUrl(urlStr) {
  try {
    const parts = new URL(urlStr).pathname.replace(/^\//, '').split('/');
    const idx = parts.indexOf('blogs');
    if (idx >= 0 && parts.length >= idx + 3) {
      return { blog: parts[idx + 1], slug: parts[idx + 2] };
    }
  } catch (_) {}
  return { blog: '', slug: '' };
}

async function main() {
  // Step 1: collect article URLs from sitemap
  const articleUrls = [];
  let page = 1;
  while (true) {
    const smUrl = `${shopUrl}/sitemap_blogs_${page}.xml`;
    console.log(`Fetching ${smUrl}`);
    let resp;
    try {
      resp = await fetchUrl(smUrl);
    } catch (e) {
      if (page === 1) {
        console.error(`No blog sitemap found at ${smUrl}: ${e.message}`);
        process.exit(1);
      }
      break;
    }
    if (resp.statusCode === 404 || resp.statusCode >= 400) {
      if (page === 1) {
        console.error(`Sitemap returned ${resp.statusCode} at ${smUrl}`);
        process.exit(1);
      }
      break;
    }
    // Extract <loc> entries
    const locRe = /<loc>([^<]+)<\/loc>/g;
    let locMatch;
    let count = 0;
    while ((locMatch = locRe.exec(resp.body)) !== null) {
      articleUrls.push(locMatch[1].trim());
      count++;
    }
    if (count === 0) break;
    console.log(`  got ${count} article URLs (total: ${articleUrls.length})`);
    page++;
  }

  if (articleUrls.length === 0) {
    console.warn('No article URLs found. Writing empty data/articles.json.');
  }

  // Step 2: fetch each article
  const results = [];
  for (const url of articleUrls) {
    console.log(`Fetching ${url}`);
    let html;
    try {
      const r = await fetchUrl(url);
      html = r.body;
    } catch (e) {
      console.warn(`Failed to fetch ${url}: ${e.message}. Skipping.`);
      continue;
    }

    const title = extractFirst(html, /<title[^>]*>([\s\S]*?)<\/title>/i).trim();
    let metaDesc = extractFirst(html, /<meta\s+name\s*=\s*["']description["'][^>]*\s+content\s*=\s*["']([^"']*)["'][^>]*>/i);
    if (!metaDesc) {
      metaDesc = extractFirst(html, /<meta\s+content\s*=\s*["']([^"']*)["'][^>]*\s+name\s*=\s*["']description["'][^>]*>/i);
    }
    const published = extractFirst(html, /<meta\s+property\s*=\s*["']article:published_time["'][^>]*\s+content\s*=\s*["']([^"']+)["'][^>]*>/i);
    const modified = extractFirst(html, /<meta\s+property\s*=\s*["']article:modified_time["'][^>]*\s+content\s*=\s*["']([^"']+)["'][^>]*>/i);

    // Body: prefer <article>, then <main>, then full HTML
    let body = '';
    const articleM = html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/i);
    if (articleM) {
      body = articleM[1];
    } else {
      const mainM = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i);
      if (mainM) {
        body = mainM[1];
      } else {
        body = html;
      }
    }

    const images = extractImages(body);
    const { blog, slug } = parseArticleUrl(url);

    results.push({ url, title, blog, slug, body_html: body, meta_description: metaDesc, published_at: published, modified_at: modified, images });
  }

  // Sort by URL for diff-friendly snapshots
  results.sort((a, b) => a.url.localeCompare(b.url));

  const dataDir = path.join(root, 'data');
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
  const out = path.join(dataDir, 'articles.json');
  fs.writeFileSync(out, JSON.stringify(results, null, 2), 'utf8');
  console.log(`\nWrote ${results.length} articles to ${out}`);
}

main().catch(e => { console.error(e); process.exit(1); });
