# Single source of truth for the V2 build.
# Consumers: scripts/gate.py, scripts/sim.py, scripts/synth.py.
# Order matters: packages first, then leaves, then the integration top.
# NEVER compile rtl/*.sv with a wildcard -- that is what let a second
# definition of mgc3130_v2_top silently win.

rtl/v2_contract_pkg.sv
rtl/v2_input_pkg.sv
rtl/v2_touch_info_decoder.sv
rtl/mgc3130_input_latch.sv
rtl/v2_input_calibration.sv
rtl/v2_position_validity.sv
rtl/v2_cursor_filter_timed.sv
rtl/v2_tick_gen.sv
rtl/v2_wt_position.sv
rtl/v2_wt_mix.sv
rtl/v2_wt_voice_bufs.sv
rtl/v2_wt_voice_engine.sv
rtl/v2_live_tempo.sv
rtl/v2_live_rule_engine.sv
rtl/v2_loop_event_recorder.sv
rtl/v2_loop_event_store_dpb.sv
rtl/v2_loop_scheduler.sv
rtl/v2_loop_contour_capture.sv
rtl/v2_loop_rest_purify.sv
rtl/v2_loop_commit_writer.sv
rtl/v2_potts_commit_fsm.sv
rtl/v2_note_increment_rom.sv
rtl/v2_voice_state_bank.sv
rtl/v2_voice_engine_banked.sv
rtl/v2_fx_lite.sv
rtl/v2_patch_bank.sv
rtl/v2_wavetable_loader.sv
rtl/v2_clock_gen.sv
rtl/v2_reset_sync.sv
rtl/v2_sample_scheduler.sv
rtl/i2s_pcm5102a_tx.sv
rtl/uart_rx.sv
rtl/uart_tx.sv
rtl/v2_uart_link.sv
rtl/v2_telemetry_snapshot.sv
rtl/mgc3130_reset_seq.sv
rtl/mgc3130_reader.sv
rtl/v2_wt_playback.sv
rtl/mgc3130_v2_top.sv
rtl/v2_test_mode.sv
rtl/v2_board_top.sv
