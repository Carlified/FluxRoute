unit UConstants;

// Single source of truth for the numeric tuning constants that shape the
// algorithms: maze-router costs, resonance-marker geometry, trace rendering,
// live-feedback throttle, placement sweeps, buffer packing, and view/render
// clamps. One module, so a knob is tuned (and can be documented and tested) in
// one place instead of being buried in the middle of a method.

interface

const
  // Maze router (LeeRoute): preference of straight runs over turns/vias.
  TurnPenalty = 3;  // extra cost for a turn (vs. going straight)
  ViaPenalty = 8;   // extra cost for a via (layer switch)

  // Resonance danger-marker geometry (DrawResonancePulses).
  DangerHalfWidthBlocks = 0.25; // danger-band rectangle half-width, core blocks

  // Trace rendering / routing feedback.
  TraceThick = 2.0;        // routed-trace stroke width
  RepaintEvery = 8;        // live repaint+message-pump throttle (every N wires)

  // Value-based optimisation passes (OptimizePlacement).
  MaxCrossPasses = 40;  // neighbour-only untangle sweeps
  MaxOrderPasses = 100; // full barycentre sweeps

  // Buffer-packing slack (InsertBufferForTrace): max-reach target = Limit*(1-lw).
  MaxReachLeeway = 0.1;

  // Rendering / view clamps (shared by the floorplan and routing canvases).
  GridHalf = 0.75;   // half-thickness (px) of the block grid lines
  BorderHalf = 1.5;  // half-thickness (px) of the die boundary
  MinBlockPx = 3.0;  // below this on-screen block size, skip the cell grid
  MaxGridBlocks = 4096; // die grid cap (visualisation guard)
  MaxDieGrowthFactor = 4.0; // bias expansion may widen the die to this multiple

implementation

end.
