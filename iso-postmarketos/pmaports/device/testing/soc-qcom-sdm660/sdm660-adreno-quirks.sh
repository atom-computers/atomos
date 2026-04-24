# Workaround for *some* bugs in mesa for lower-end
# Adreno 5xx GPUs (508/509/512).
# Remove this when this mesa bug is fixed:
# https://gitlab.freedesktop.org/mesa/mesa/-/issues/8442
export FD_MESA_DEBUG=noblit

# A508 owners can try to uncomment this:
# export FD_MESA_DEBUG=noblit,inorder,gmem
