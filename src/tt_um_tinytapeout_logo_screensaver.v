/*
 * Copyright (c) 2024 Tiny Tapeout LTD
 * SPDX-License-Identifier: Apache-2.0
 * Author: Uri Shaked / Pipelined Optimization
 */

`default_nettype none

parameter LOGO_SIZE = 128;  // Size of the logo in pixels
parameter DISPLAY_WIDTH = 640;  // VGA display width
parameter DISPLAY_HEIGHT = 480;  // VGA display height

// Pre-calculated boundary thresholds to shorten the critical path
localparam [9:0] MAX_X_BOUND = DISPLAY_WIDTH - LOGO_SIZE;
localparam [9:0] MAX_Y_BOUND = DISPLAY_HEIGHT - LOGO_SIZE;

`define COLOR_WHITE 3'd7

module tt_um_tinytapeout_logo_screensaver (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // VGA signals from generator
  wire hsync;
  wire vsync;
  wire video_active;
  wire [9:0] pix_x;
  wire [9:0] pix_y;

  // Balanced Pipeline registers for VGA control signals (3-stage delay match)
  reg hsync_r1, hsync_r2, hsync_r3;
  reg vsync_r1, vsync_r2, vsync_r3;
  reg video_active_r1, video_active_r2, video_active_r3;

  // Final color output registers (Stage 3 registered outputs)
  reg [1:0] R;
  reg [1:0] G;
  reg [1:0] B;

  // Configuration
  wire cfg_tile        = ui_in;
  wire cfg_solid_color = ui_in;

  // TinyVGA PMOD
  assign uo_out  = {hsync_r3, B [ 0 ], G [ 0 ], R [ 0 ], vsync_r3, B [ 1 ], G [ 1 ], R [ 1 ]};

  // Gamepad Pmod
  wire gamepad_start, gamepad_up, gamepad_down, gamepad_left, gamepad_right;
  reg gamepad_start_prev;

  /* verilator lint_off PINMISSING */
  gamepad_pmod_single gamepad (
      // Inputs:
      .rst_n(rst_n),
      .clk(clk),
      .pmod_data(ui_in),
      .pmod_clk(ui_in),
      .pmod_latch(ui_in),

      // Outputs:
      .start(gamepad_start),
      .up(gamepad_up),
      .down(gamepad_down),
      .left(gamepad_left),
      .right(gamepad_right)
  );
  /* verilator lint_on PINMISSING */

  // Unused outputs assigned to 0.
  assign uio_out = 0;
  assign uio_oe  = 0;

  // Suppress unused signals warning
  wire _unused_ok = &{ena, ui_in, ui_in[3:2], uio_in};

  reg [9:0] prev_y;

  vga_sync_generator vga_sync_gen (
      .clk(clk),
      .reset(~rst_n),
      .hsync(hsync),
      .vsync(vsync),
      .display_on(video_active),
      .hpos(pix_x),
      .vpos(pix_y)
  );

  reg [9:0] logo_left;
  reg [9:0] logo_top;
  reg dir_x;
  reg dir_y;
  reg manual_mode;

  wire pixel_value;
  reg [2:0] color_index;
  wire [5:0] pallete_color;
  wire [5:0] color;

  // -------------------------------------------------------------------------
  // PIPELINE REGISTERS & TRACKING SIGNALS
  // -------------------------------------------------------------------------
  
  // Pipeline Stage 1 registers: Isolate address math additions/subtractions
  (* keep = 1 *) reg [6:0] rom_addr_x;
  (* keep = 1 *) reg [6:0] rom_addr_y;
  (* keep = 1 *) reg [9:0] x_offset_r1;
  (* keep = 1 *) reg [9:0] y_offset_r1;
  (* keep = 1 *) reg       cfg_tile_r1;
  (* keep = 1 *) reg [5:0] color_r1;

  // Pipeline Stage 2 registers: Independent Spatial bounding matching
  (* keep = 1 *) reg       logo_pixels_r2;
  (* keep = 1 *) reg       cfg_tile_r2;
  (* keep = 1 *) reg [5:0] color_r2;

  // Instantiate sub-modules (Address evaluated in Stage 1, data ready in Stage 2)
  bitmap_rom rom1 (
      .x(rom_addr_x),
      .y(rom_addr_y),
      .pixel(pixel_value)
  );

  palette palette_inst (
      .color_index(color_index),
      .rrggbb(pallete_color)
  );

  wire [9:0] x_sub = pix_x - logo_left;
  wire [9:0] y_sub = pix_y - logo_top;
  wire [5:0] gradient_color = {1'b1, y_sub[6:2] - x_sub[6:2] + logo_left[6:2]};
  assign color = cfg_solid_color ? pallete_color : gradient_color;

  // =========================================================================
  // PIPELINE STAGE 1: Coordinate Isolation Math
  // =========================================================================
  always @(posedge clk) begin
    if (~rst_n) begin
      rom_addr_x      <= 0;
      rom_addr_y      <= 0;
      x_offset_r1     <= 0;
      y_offset_r1     <= 0;
      cfg_tile_r1     <= 0;
      color_r1        <= 0;
      hsync_r1        <= 1;
      vsync_r1        <= 1;
      video_active_r1 <= 0;
    end else begin
      rom_addr_x      <= pix_x[6:0] - logo_left[6:0];
      rom_addr_y      <= pix_y[6:0] - logo_top[6:0];
      x_offset_r1     <= pix_x - logo_left;
      y_offset_r1     <= pix_y - logo_top;
      cfg_tile_r1     <= cfg_tile;
      color_r1        <= color;

      hsync_r1        <= hsync;
      vsync_r1        <= vsync;
      video_active_r1 <= video_active;
    end
  end

  // =========================================================================
  // PIPELINE STAGE 2: Spatial Check Comparison Matching
  // =========================================================================
  always @(posedge clk) begin
    if (~rst_n) begin
      logo_pixels_r2  <= 0;
      cfg_tile_r2     <= 0;
      color_r2        <= 0;
      hsync_r2        <= 1;
      vsync_r2        <= 1;
      video_active_r2 <= 0;
    end else begin
      logo_pixels_r2  <= (x_offset_r1[9:7] == 0 && y_offset_r1[9:7] == 0);
      cfg_tile_r2     <= cfg_tile_r1;
      color_r2        <= color_r1;

      hsync_r2        <= hsync_r1;
      vsync_r2        <= vsync_r1;
      video_active_r2 <= video_active_r1;
    end
  end

  // =========================================================================
  // PIPELINE STAGE 3: Merge spatial hits & gate final registered RGB out
  // =========================================================================
  always @(posedge clk) begin
    if (~rst_n) begin
      R               <= 0;
      G               <= 0;
      B               <= 0;
      hsync_r3        <= 1;
      vsync_r3        <= 1;
      video_active_r3 <= 0;
    end else begin
      hsync_r3        <= hsync_r2;
      vsync_r3        <= vsync_r2;
      video_active_r3 <= video_active_r2;

      R <= 0;
      G <= 0;
      B <= 0;
      if (video_active_r2 && (cfg_tile_r2 || logo_pixels_r2)) begin
        R <= pixel_value ? color_r2[5:4] : 0;
        G <= pixel_value ? color_r2[3:2] : 0;
        B <= pixel_value ? color_r2[1:0] : 0;
      end
    end
  end

  // =========================================================================
  // Object Physics (Safe outside active drawing critical paths)
  // =========================================================================
  always @(posedge clk) begin
    if (~rst_n) begin
      logo_left          <= 200;
      logo_top           <= 200;
      dir_y              <= 0;
      dir_x              <= 1;
      color_index        <= 0;
      prev_y             <= 10'd1;
      gamepad_start_prev <= 0;
      manual_mode        <= 0;
    end else begin
      prev_y <= pix_y;
      if (pix_y == 0 && prev_y != pix_y) begin
        if (manual_mode) begin
          logo_manual_control();
        end else begin
          bounce_logo();
        end
        if (gamepad_start & ~gamepad_start_prev) begin
          manual_mode <= ~manual_mode;
        end
        gamepad_start_prev <= gamepad_start;
      end
    end
  end

  task logo_manual_control;
    if (gamepad_left && logo_left > 0) begin
      logo_left <= logo_left - 1;
    end
    if (gamepad_right && logo_left < (MAX_X_BOUND - 10'd1)) begin
      logo_left <= logo_left + 1;
    end
    if (gamepad_up && logo_top > 0) begin
      logo_top <= logo_top - 1;
    end
    if (gamepad_down && logo_top < (MAX_Y_BOUND - 10'd1)) begin
      logo_top <= logo_top + 1;
    end
  endtask

  task bounce_logo;
    logo_left <= logo_left + (dir_x ? 1 : -1);
    logo_top  <= logo_top + (dir_y ? 1 : -1);

    if (gamepad_left) begin
      dir_x <= 0;
    end else if (gamepad_right) begin
      dir_x <= 1;
    end

    if (gamepad_up) begin
      dir_y <= 0;
    end else if (gamepad_down) begin
      dir_y <= 1;
    end

    // Horizontal check using lookahead direct comparisons
    if (logo_left == 10'd1 && !dir_x) begin
      dir_x <= 1;
      color_index <= color_index + 1;
    end
    if (logo_left == (MAX_X_BOUND - 10'd1) && dir_x) begin
      dir_x <= 0;
      color_index <= color_index + 1;
    end
    
    // Vertical check using lookahead direct comparisons
    if (logo_top == 10'd1 && !dir_y) begin
      dir_y <= 1;
      color_index <= color_index + 1;
    end
    if (logo_top == (MAX_Y_BOUND - 10'd1) && dir_y) begin
      dir_y <= 0;
      color_index <= color_index + 1;
    end
  endtask

endmodule