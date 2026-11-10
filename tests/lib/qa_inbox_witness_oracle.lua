-- Independent protocol-v2 vector: explicit known fixture order, not Source calls.
local function frame(fields)
  local out={}
  for _,value in ipairs(fields) do out[#out+1]=tostring(#value)..':'..value end
  return table.concat(out)
end
return function(F,root,recipient)
  local hash=F.sha(frame({'source-progress-v2',root,recipient}))
  local function record(path,presence,offset,bytes)
    hash=F.sha(frame({hash,path,presence,tostring(offset),tostring(#bytes),F.sha(bytes)}))
  end
  for _,path in ipairs({'inboxes/'..recipient..'.jsonl','read/'..recipient..'.jsonl'}) do
    local bytes=assert(F.read(root..'/'..path))
    assert(#bytes<65536,'vector must remain one fixed log chunk')
    record(path,'present',0,bytes)
    record(path,'eof',#bytes,'')
  end
  -- Explicit delivery/role traversal. QB shares QA body and note, folded once.
  for _,path in ipairs({'messages/QA.json','objects/protocol-shared',
    'objects/protocol-note','messages/QB.json'}) do
    record(path,'present',0,assert(F.read(root..'/'..path)))
  end
  return 'source-progress-v2:sha256:'..hash
end
