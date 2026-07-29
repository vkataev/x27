# Mesh of Tensix Cores

- Compute mesh: a generated 2D array of Tensix cores.
- NoC interconnect: explicit wiring of neighbor outputs to inputs; boundaries tied to I/O.
- Memory controllers: aggregate per-core DRAM requests and drive external channels.
- Host/PCIe bridge: converts host commands into NoC packets injected at the mesh edge.
- Boot control: a tiny state machine that brings the chip out of reset.
- Simplifications to be aware of:
  - Real chips have hundreds of cores, not 4×4.
  - The NoC is much more than direct wiring: it has routers, virtual channels, credit-based flow control, and multicast.
  - DRAM controllers are usually high-bandwidth HBM2e/HBM3 PHYs, not simple aggregators.
  - There is normally a separate management/NoC configuration network, a clock/reset/power controller, and sometimes a host CPU complex on-die.


## Tech Specs
 
<section id="card-comparison-table">
<h3 id="card-comparison-table">Card Comparison Table<a class="headerlink" href="#card-comparison-table" title="Link to this heading">#</a></h3>
  
<p><strong>NOTE:</strong> The <strong>n150s and n300s add-in cards</strong> come with a heatsink for passive cooling in systems which can provide sufficient forced airflow to the card. If your system does not (for example, a desktop workstation), installing the bundled <a class="reference internal" href="ack.html"><span class="std std-doc">Active Cooling Kit</span></a> is <strong>required</strong>; we strongly recommend desktop workstations use the <strong>n150d</strong> and <strong>n300d</strong> add-in cards which are designed for desktop deployment. If the card isn’t sufficiently cooled, performance will be substantially reduced to stay in a safe operating temperature range and you risk damage to the card.</p>
  
<div class="wy-table-responsive"><table class="docutils align-default">
<thead>
<tr class="row-odd"><th class="head"><p>Specification</p></th>
<th class="head"><p>n150d</p></th>
<th class="head"><p>n150s</p></th>
<th class="head"><p>n300d</p></th>
<th class="head"><p>n300s</p></th>
</tr>
</thead>
<tbody>
<tr class="row-even"><td><p>Part Number</p></td>
<td><p>TC-02002</p></td>
<td><p>TC-02001</p></td>
<td><p>TC-02004</p></td>
<td><p>TC-02003</p></td>
</tr>
<tr class="row-odd"><td><p>Wormhole™ ASICs</p></td>
<td><p>1</p></td>
<td><p>1</p></td>
<td><p>2</p></td>
<td><p>2</p></td>
</tr>
<tr class="row-even"><td><p>Tensix Cores</p></td>
<td><p>72</p></td>
<td><p>72</p></td>
<td><p>128 (64 per ASIC)</p></td>
<td><p>128 (64 per ASIC)</p></td>
</tr>
<tr class="row-odd"><td><p>AI Clock</p></td>
<td><p>1 GHz</p></td>
<td><p>1 GHz</p></td>
<td><p>1 GHz</p></td>
<td><p>1 GHz</p></td>
</tr>
<tr class="row-even"><td><p>SRAM</p></td>
<td><p>108 MB</p></td>
<td><p>108 MB</p></td>
<td><p>192 MB (96 MB per ASIC)</p></td>
<td><p>192 MB (96 MB per ASIC)</p></td>
</tr>
<tr class="row-odd"><td><p>Memory</p></td>
<td><p>12 GB GDDR6</p></td>
<td><p>12 GB GDDR6</p></td>
<td><p>24 GB GDDR6</p></td>
<td><p>24 GB GDDR6</p></td>
</tr>
<tr class="row-even"><td><p>Memory Speed</p></td>
<td><p>12 GT/sec</p></td>
<td><p>12 GT/sec</p></td>
<td><p>12 GT/sec</p></td>
<td><p>12 GT/sec</p></td>
</tr>
<tr class="row-odd"><td><p>Memory Bandwidth</p></td>
<td><p>288 GB/sec</p></td>
<td><p>288 GB/sec</p></td>
<td><p>576 GB/sec</p></td>
<td><p>576 GB/sec</p></td>
</tr>
<tr class="row-even"><td><p>TeraFLOPS (FP8)</p></td>
<td><p>262</p></td>
<td><p>262</p></td>
<td><p>466</p></td>
<td><p>466</p></td>
</tr>
<tr class="row-odd"><td><p>TeraFLOPS (FP16)</p></td>
<td><p>74</p></td>
<td><p>74</p></td>
<td><p>131</p></td>
<td><p>131</p></td>
</tr>
<tr class="row-even"><td><p>TeraFLOPS (BLOCKFP8)</p></td>
<td><p>148</p></td>
<td><p>148</p></td>
<td><p>262</p></td>
<td><p>262</p></td>
</tr>
<tr class="row-odd"><td><p>TBP (Total Board Power)</p></td>
<td><p>160W</p></td>
<td><p>160W</p></td>
<td><p>300W</p></td>
<td><p>300W</p></td>
</tr>
<tr class="row-even"><td><p>External Power</p></td>
<td><p>1x 4+4-pin EPS12V</p></td>
<td><p>1x 4+4-pin EPS12V</p></td>
<td><p>1x 4+4-pin EPS12V</p></td>
<td><p>1x 4+4-pin EPS12V</p></td>
</tr>
<tr class="row-odd"><td><p>Connectivity</p></td>
<td><p>2x Warp 100 Bridge<br>2x QSFP-DD 200G (Active)*</p></td>
<td><p>2x Warp 100 Bridge<br>2x QSFP-DD 200G (Active)*</p></td>
<td><p>2x Warp 100 Bridge<br>2x QSFP-DD 200G (Active)*</p></td>
<td><p>2x Warp 100 Bridge<br>2x QSFP-DD 200G (Active)*</p></td>
</tr>
<tr class="row-even"><td><p>Internal Chip-to-Chip</p></td>
<td><p>N/A</p></td>
<td><p>N/A</p></td>
<td><p>200G</p></td>
<td><p>200G</p></td>
</tr>
<tr class="row-odd"><td><p>System Interface</p></td>
<td><p>PCI Express 4.0 x16</p></td>
<td><p>PCI Express 4.0 x16</p></td>
<td><p>PCI Express 4.0 x16</p></td>
<td><p>PCI Express 4.0 x16</p></td>
</tr>
<tr class="row-even"><td><p>Cooling</p></td>
<td><p>Active (Axial Fan)</p></td>
<td><p>Passive</p></td>
<td><p>Active (Axial Fan)</p></td>
<td><p>Passive</p></td>
</tr>
<tr class="row-odd"><td><p>Dimensions (WxDxH)</p></td>
<td><p>52.2mm x 256mm x 111mm</p></td>
<td><p>36mm x 254mm x 111mm</p></td>
<td><p>52.2mm x 256mm x 111mm</p></td>
<td><p>36mm x 254mm x 111mm</p></td>
</tr>
<tr class="row-even"><td><p>Dimensions (w/ Cooling Kit) (WxDxH)</p></td>
<td><p>N/A</p></td>
<td><p>36mm x 393.5mm x 114mm</p></td>
<td><p>N/A</p></td>
<td><p>36mm x 393.5mm x 114mm</p></td>
</tr>
</tbody>
</table></div>
<p>*<em>For connecting to Tenstorrent Wormhole™-based cards only.</em></p>
<p><img alt="" src="../../_images/wh_dimensions.png"></p>
<p><em>n150s/n300s without Active Cooling Kit</em></p>
</section>
