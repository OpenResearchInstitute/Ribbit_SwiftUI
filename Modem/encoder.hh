/*
Encoder for Ribbit

Copyright 2023 Ahmet Inan <inan@aicodix.de>
*/

#pragma once

#include <cmath>
#include <iostream>
#include <algorithm>
#include "simplex_encoder.hh"
#include "permute.hh"
#include "xorshift.hh"
#include "complex.hh"
#include "bitman.hh"
#include "deque.hh"
#include "polar.hh"
#include "utils.hh"
#include "const.hh"
#include "fft.hh"
#include "mls.hh"
#include "psk.hh"

class Encoder {
	typedef DSP::Complex<float> cmplx;
	typedef int8_t code_type;
	typedef PhaseShiftKeying<4, cmplx, code_type> qpsk;
	static const int code_order = 12;
	static const int mesg_bytes = 256;
	static const int code_len = 1 << code_order;
	static const int meta_len = 63;
	static const int symbol_length = 256;
	static const int subcarrier_count = 64;
	static const int payload_symbols = 32;
	static const int noise_symbols = 14;
	static const int first_subcarrier = 16;
	static const int guard_length = symbol_length / 8;
	static const int extended_length = symbol_length + guard_length;
	DSP::FastFourierTransform<symbol_length, cmplx, 1> bwd;
	DSP::Deque<float, 3 * extended_length> buffer;
	CODE::MLS noise_seq;
	CODE::SimplexEncoder<6> simplex;
	CODE::FisherYatesShuffle<code_len> shuffle;
	PolarEncoder<code_type> polar;
	cmplx temp[symbol_length], freq[symbol_length];
	float guard[guard_length];
	uint8_t mesg[mesg_bytes];
	code_type code[code_len], meta[meta_len];
	int symbol_number = payload_symbols;
	int count_down = 0;
	int noise_count = 0;

	static int nrz(bool bit) {
		return 1 - 2 * bit;
	}

	void noise_symbol() {
		float factor = std::sqrt(symbol_length / float(subcarrier_count));
		for (int i = 0; i < subcarrier_count; ++i)
			freq[first_subcarrier + i] = factor * cmplx(nrz(noise_seq()), nrz(noise_seq()));
		symbol();
	}

	void schmidl_cox() {
		CODE::MLS seq(0b1100111);
		freq[first_subcarrier] = std::sqrt(float(2 * symbol_length) / subcarrier_count);
		for (int i = first_subcarrier + 1; i < first_subcarrier + subcarrier_count; ++i)
			freq[i] = freq[i - 1] * cmplx(nrz(seq()));
		symbol();
		symbol(false);
	}

	void preamble(int data) {
		simplex(meta, data);
		CODE::MLS seq(0b1000011);
		freq[first_subcarrier] = std::sqrt(float(symbol_length) / subcarrier_count);
		for (int i = 0; i < meta_len; ++i)
			freq[first_subcarrier + 1 + i] = freq[first_subcarrier + i] * cmplx(meta[i] * nrz(seq()));
		symbol();
	}

	void payload_symbol() {
		for (int i = 0; i < subcarrier_count; ++i)
			freq[first_subcarrier + i] *= qpsk::map(code + 2 * (subcarrier_count * symbol_number + i));
		symbol();
	}

	void silence() {
		for (int i = 0; i < symbol_length; ++i)
			freq[i] = 0;
		symbol();
	}

	void symbol(bool output_guard = true) {
		bwd(temp, freq);
		for (int i = 0; i < symbol_length; ++i)
			temp[i] /= std::sqrt(float(8 * symbol_length));
		for (int i = 0; output_guard && i < guard_length; ++i) {
			float x = i / float(guard_length - 1);
			float ratio(0.5);
			x = std::min(x, ratio) / ratio;
			float y = 0.5f * (1 - std::cos(DSP::Const<float>::Pi() * x));
			float sum = DSP::lerp(guard[i], temp[i + symbol_length - guard_length].real(), y);
			buffer.push_front(sum);
		}
		for (int i = 0; i < guard_length; ++i)
			guard[i] = temp[i].real();
		for (int i = 0; i < symbol_length; ++i)
			buffer.push_front(temp[i].real());
	}

	bool produce() {
		if (buffer.size() > buffer.max_size() - 2 * extended_length)
			return false;
		switch (count_down) {
			case 5:
				if (noise_count) {
					--noise_count;
					noise_symbol();
					break;
				}
				--count_down;
			case 4:
				schmidl_cox();
				--count_down;
				break;
			case 3:
				preamble(1);
				--count_down;
				break;
			case 2:
				payload_symbol();
				if (++symbol_number == payload_symbols)
					--count_down;
				break;
			case 1:
				silence();
				--count_down;
				break;
			default:
				return false;
		}
		return true;
	}

public:
	Encoder() : noise_seq(0b100101010001) {}

	bool read(float *audio_buffer, int sample_count) {
		for (int i = 0; i < sample_count; ++i) {
			produce();
			if (buffer.size()) {
				audio_buffer[i] = buffer.back();
				buffer.pop_back();
			} else {
				audio_buffer[i] = 0;
			}
		}
		return !buffer.size();
	}

	void init(const uint8_t *payload) {
		symbol_number = 0;
		count_down = 5;
		noise_count = noise_symbols;
		for (int i = 0; i < guard_length; ++i)
			guard[i] = 0;
		CODE::Xorshift32 scrambler;
		for (int i = 0; i < mesg_bytes; ++i)
			mesg[i] = payload[i] ^ scrambler();
		polar(code, mesg);
		shuffle(code);
	}
};

