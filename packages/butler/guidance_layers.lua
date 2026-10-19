-- User-managed guidance layers (remuda-butler#535). Butler's own text is the
-- framework layer; the cluster, team, personal and machine-local layers are
-- files the user keeps outside the framework, read in that fixed order. A
-- missing file means "not loaded" and nothing fails, like an optional
-- `custom.el` include. The loaded layers are written into the agent's
-- AGENTS.md as one managed block (guidance_blocks.lua), so an agent that
-- restarts, resumes or compacts reads them from the file, not from the
-- conversation.
--
-- Pure: the caller passes the reads and the hash, so this file does no I/O.
local guidance_layers = {}

guidance_layers.BLOCK_ID = "guidance-layers"
guidance_layers.LAYER_MAX = 8192
-- The block holds every user layer plus the report.
guidance_layers.BLOCK_MAX = 4 * guidance_layers.LAYER_MAX + 4096
guidance_layers.CLUSTER_WAITING = "not available (this Remuda core has no cluster file store; update Remuda)"
-- The one cluster file every node reads (warmblood-kr/remuda#741). Publish it with
-- `remuda vfs put FILE remuda:///butler/guidance/cluster.md`.
guidance_layers.CLUSTER_URI = "remuda:///butler/guidance/cluster.md"

-- The user layers after framework and cluster, in load order. `local` is the
-- machine-local include: keep it out of a shared dotfiles repository.
guidance_layers.FILES = {
  { id = "team", file = "team.md" },
  { id = "personal", file = "personal.md" },
  { id = "local", file = "local.md" },
}

-- The guidance directory: REMUDA_BUTLER_GUIDANCE_DIR, else
-- CONFIG_HOME/remuda/butler/guidance. nil when neither is known.
function guidance_layers.dir(getenv, config_home)
  local override = getenv("REMUDA_BUTLER_GUIDANCE_DIR")
  if override and override ~= "" then return override end
  return config_home and (config_home .. "/remuda/butler/guidance") or nil
end

local function version(hash, text)
  local ok, digest = pcall(hash, text)
  return ok and type(digest) == "string" and ("sha256:" .. digest:sub(1, 12)) or "unhashed"
end

-- load(opts) -> layers, in order. opts:
--   framework   Butler's own text for this agent (hashed for its version)
--   dir         the guidance directory, or nil
--   read(path)  text | nil (absent) | nil, reason (exists but unreadable)
--   hash(text)  hex sha256
--   cluster     optional { status, version, text, source }, from cluster_from_vfs
-- Each layer: { id, status, source, version, bytes, text }. status is loaded,
-- missing, empty, unreadable, too-large or unavailable; text is set only
-- when loaded.
function guidance_layers.load(opts)
  local layers = {}
  local framework = opts.framework or ""
  layers[1] = { id = "framework", status = "loaded", source = "built in",
    version = version(opts.hash, framework), bytes = #framework }
  local cluster = opts.cluster
  if type(cluster) == "table" and cluster.status == "loaded" and type(cluster.text) == "string" then
    local too_large = #cluster.text > guidance_layers.LAYER_MAX
    layers[2] = { id = "cluster", status = too_large and "too-large" or "loaded", source = cluster.source or "cluster",
      version = cluster.version or version(opts.hash, cluster.text), bytes = #cluster.text,
      text = not too_large and cluster.text or nil }
  elseif type(cluster) == "table" then
    layers[2] = { id = "cluster", status = cluster.status ~= "loaded" and cluster.status or "unavailable",
      source = cluster.source or cluster.reason or guidance_layers.CLUSTER_WAITING, version = cluster.version }
  else
    layers[2] = { id = "cluster", status = "unavailable", source = guidance_layers.CLUSTER_WAITING }
  end
  for _, spec in ipairs(guidance_layers.FILES) do
    local path = opts.dir and (opts.dir .. "/" .. spec.file) or nil
    local layer = { id = spec.id, source = path or "no guidance directory" }
    if not path then
      layer.status = "missing"
    else
      local text, why = opts.read(path)
      if text == nil then
        layer.status = why and "unreadable" or "missing"
      elseif not text:find("%S") then
        layer.status, layer.bytes = "empty", #text
      elseif #text > guidance_layers.LAYER_MAX then
        layer.status, layer.bytes = "too-large", #text
      else
        layer.status, layer.bytes, layer.text = "loaded", #text, text
        layer.version = version(opts.hash, text)
      end
    end
    layers[#layers + 1] = layer
  end
  return layers
end

-- The cluster layer from the cluster file store (`remuda.vfs`, remuda#742), or
-- nil when this core has none. Every call answers from this node's own index
-- and cache, never the network. The version is "vN/sha256:" plus 12 hex digits.
function guidance_layers.cluster_from_vfs(vfs)
  local uri = guidance_layers.CLUSTER_URI
  if type(vfs) ~= "table" or type(vfs.stat) ~= "function" or type(vfs.read) ~= "function" then return nil end
  local function failed(code)
    return { status = "unavailable", source = "cannot be read from the cluster file store (" .. code .. ")" }
  end
  local ok, entry, why = pcall(vfs.stat, uri)
  if not ok then return failed("error") end
  if type(entry) ~= "table" then
    local code = tostring(why):match("^([%w_]+)") or "error"
    if code == "no_cluster" then
      return { status = "unavailable", source = "not in a cluster (this node has no cluster identity)" }
    end
    if code == "not_found" then return { status = "missing", source = uri } end
    return failed(code)
  end
  local version = "v" .. tostring(entry.version) .. "/sha256:" .. tostring(entry.sha256):sub(1, 12)
  if entry["local"] == false then
    return { status = "unavailable", version = version,
      source = "version " .. version .. " is not copied to this node yet" }
  end
  if tonumber(entry.size) and tonumber(entry.size) > guidance_layers.LAYER_MAX then
    return { status = "too-large", source = uri, version = version }
  end
  local read_ok, text, read_why = pcall(vfs.read, uri)
  if not read_ok then return failed("error") end
  if type(text) ~= "string" then return failed(tostring(read_why):match("^([%w_]+)") or "error") end
  if not text:find("%S") then return { status = "empty", source = uri, version = version } end
  local source = uri
  if entry.synced_at == nil then source = source .. " (this node has not synced with another node yet)" end
  return { status = "loaded", text = text, version = version, source = source }
end

-- One line for traces and reports: "framework=sha256:... cluster=unavailable ...".
function guidance_layers.summary(layers)
  local parts = {}
  for _, layer in ipairs(layers) do
    parts[#parts + 1] = layer.id .. "=" .. (layer.status == "loaded" and layer.version or layer.status)
  end
  return table.concat(parts, " ")
end

local function show_path(path, home)
  if home and home ~= "" and path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
  return path
end

local DESCRIBE = {
  missing = "not loaded (no file at %s)",
  empty = "not loaded (%s is empty)",
  unreadable = "not loaded (%s cannot be read)",
  ["too-large"] = "not loaded (%s is over 8 KiB)",
  unavailable = "%s",
}

-- The managed block's body: the layer list, then each loaded user layer.
function guidance_layers.render(layers, home)
  local out = {
    "## Guidance layers",
    "",
    "Butler loaded these guidance layers in this order when this session started.",
    "A later layer adds to or overrides an earlier one. Edit the files named here,",
    "not this block: Butler rewrites it on every session start.",
    "",
  }
  for _, layer in ipairs(layers) do
    local line
    if layer.status == "loaded" then
      line = "loaded from " .. show_path(layer.source, home) .. ", version " .. layer.version
      if layer.id == "framework" then line = "built in, version " .. layer.version end
    else
      line = DESCRIBE[layer.status]:format(show_path(layer.source, home))
    end
    out[#out + 1] = "- " .. layer.id .. ": " .. line
  end
  for _, layer in ipairs(layers) do
    if layer.text then
      out[#out + 1] = ""
      out[#out + 1] = "### " .. layer.id .. " guidance"
      out[#out + 1] = ""
      out[#out + 1] = (layer.text:gsub("\r\n", "\n"):gsub("\n+$", ""))
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- A body holding a managed marker line would be refused by guidance_blocks;
-- report the layer as unreadable instead of dropping the whole block.
function guidance_layers.sanitize(layers)
  for _, layer in ipairs(layers) do
    if layer.text and layer.text:find("remuda%-butler:managed id=") then
      layer.text, layer.status = nil, "unreadable"
    end
  end
  return layers
end

if type(remuda) == "table" then remuda._butler_guidance_layers = guidance_layers end
return guidance_layers
