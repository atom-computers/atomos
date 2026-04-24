# Various GPU workarounds for Adreno a305

# The 'ngl' GTK renderer, which is now used by default, has worse
# performance and is somewhat more prone to crashes. The legacy GL
# renderer has since been removed. Use software rendering fallback.
export GSK_RENDERER=cairo
