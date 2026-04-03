"""Generate 3 zoom-level renders using SKY130 PDK layer properties."""
import pya
import sys, os

gds = "/design/runs/RUN_2026-04-02_22-22-45/49-magic-streamout/accel_top.gds"
lyp = "/root/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.tech/klayout/tech/sky130A.lyp"
lyt = "/root/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.tech/klayout/tech/sky130A.lyt"
out = "/design/images"

lv = pya.LayoutView()
lv.set_config("background-color", "#000000")
lv.set_config("grid-visible", "false")
lv.set_config("text-visible", "false")
lv.load_layout(gds)
lv.max_hier()
lv.load_layer_props(lyp)

top = lv.active_cellview().layout().top_cell()
bb = top.dbbox()
cx, cy = bb.center().x, bb.center().y
W, H = bb.width(), bb.height()
ar = W / H
res = 4096

def save(name, box):
    lv.zoom_box(box)
    w = res
    h = int(w / ar)
    lv.save_image_with_options(os.path.join(out, name), w, h, oversampling=0)
    sz = os.path.getsize(os.path.join(out, name))
    print(f"  {name}: {sz/1024/1024:.1f} MB")

print("Rendering 3 images...")

# 1) Full layout
save("01_full_layout.png", pya.DBox(bb.left, bb.bottom, bb.right, bb.top))

# 2) Routing zoom — center 12%
f = 0.12
save("02_routing_zoom.png", pya.DBox(cx-W*f/2, cy-H*f/2, cx+W*f/2, cy+H*f/2))

# 3) Transistor zoom — center 1.5%
f2 = 0.015
save("03_transistor_zoom.png", pya.DBox(cx-W*f2/2, cy-H*f2/2, cx+W*f2/2, cy+H*f2/2))

print("Done.")
