# Various GPU workarounds for Adreno a506

# Use the 'cairo' GTK renderer, so we prepare for the removal of
# the legacy GL renderer
export GSK_RENDERER=cairo
