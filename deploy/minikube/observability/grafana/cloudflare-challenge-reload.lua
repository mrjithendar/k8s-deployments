-- Grafana's sidecar, inbound, while var.grafana_public is set (minikube-infrastructure/grafana.tf, EnvoyFilter
-- grafana-cloudflare-challenge-reload; docs/grafana-public.md).
--
-- Cloudflare's human check in front of the public Grafana lasts the zone's Challenge Passage time. After that,
-- Cloudflare answers Grafana's own API calls (queries, variable values) with its challenge: 403 and the header
-- cf-mitigated: challenge. A fetch cannot solve a challenge, so panels and filters show 403 until the visitor
-- reloads. This filter adds a script to Grafana's page that does the reload itself: the visitor passes the check
-- again and lands on the same URL, which holds the time range and the variables.

-- The browser part. Loop guard: at most one automatic reload a minute per tab, and none where sessionStorage is
-- unavailable (nothing to remember the last reload in).
local SCRIPT = [==[<script>(function () {
  var fetch0 = window.fetch;
  if (!fetch0) return;
  var KEY = "grafana.cloudflare-challenge-reload";
  function reload() {
    try {
      var last = Number(window.sessionStorage.getItem(KEY)) || 0;
      if (Date.now() - last < 60000) return;
      window.sessionStorage.setItem(KEY, String(Date.now()));
    } catch (e) {
      return;
    }
    window.location.reload();
  }
  window.fetch = function () {
    return fetch0.apply(this, arguments).then(function (response) {
      if (response.status === 403 && response.headers.get("cf-mitigated") === "challenge") reload();
      return response;
    });
  };
})();</script>]==]

-- A page load (not an API call): ask Grafana for an uncompressed page, so the script can go in. The gateway
-- compresses the page on the way out (istio/edge, values compression).
local function is_page(headers)
  local dest = headers:get("sec-fetch-dest")
  if dest ~= nil then
    return dest == "document"
  end
  local accept = headers:get("accept")
  return accept ~= nil and string.find(accept, "text/html", 1, true) ~= nil
end

function envoy_on_request(request_handle)
  local headers = request_handle:headers()
  if is_page(headers) then
    headers:remove("accept-encoding")
  end
end

function envoy_on_response(response_handle)
  local headers = response_handle:headers()
  local content_type = headers:get("content-type")
  if content_type == nil or string.find(content_type, "text/html", 1, true) == nil then
    return
  end
  -- Compressed anyway (an API client that asked for text/html with Accept-Encoding): leave it alone.
  if headers:get("content-encoding") ~= nil then
    return
  end
  local body = response_handle:body()
  if body == nil then
    return
  end
  local html = body:getBytes(0, body:length())
  local _, head_end = string.find(html, "<head>", 1, true)
  if head_end == nil then
    return
  end
  -- First thing in <head>, before Grafana's own scripts take window.fetch.
  local length = body:setBytes(string.sub(html, 1, head_end) .. SCRIPT .. string.sub(html, head_end + 1))
  -- Reading the body ends the first headers handle's scope: take a new one.
  response_handle:headers():replace("content-length", tostring(length))
end
