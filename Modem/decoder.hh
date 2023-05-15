/*
Decoder for Ribbit

Copyright 2023 Ahmet Inan <inan@aicodix.de>
*/

#pragma once

#include <cmath>
#include <iostream>
#include <algorithm>

namespace DSP {
	using std::abs;
	using std::min;
	using std::cos;
	using std::sin;
}

#include "simplex_decoder.hh"
#include "schmidl_cox.hh"
#include "bip_buffer.hh"
#include "xorshift.hh"
#include "complex.hh"
#include "permute.hh"
#include "hilbert.hh"
#include "blockdc.hh"
#include "bitman.hh"
#include "phasor.hh"
#include "polar.hh"
#include "fft.hh"
#include "mls.hh"
#include "psk.hh"

class Decoder {
	typedef DSP::Complex<float> cmplx;
	typedef int8_t code_type;
	typedef PhaseShiftKeying<2, cmplx, code_type> bpsk;
	typedef PhaseShiftKeying<4, cmplx, code_type> qpsk;
	static const int code_order = 12;
	static const int mesg_bytes = 256;
	static const int code_len = 1 << code_order;
	static const int meta_len = 63;
	static const int symbol_length = 256;
	static const int guard_length = symbol_length / 8;
	static const int extended_length = symbol_length + guard_length;
	static const int filter_length = 33;
	static const int subcarrier_count = 64;
	static const int payload_symbols = 32;
	static const int first_subcarrier = -subcarrier_count / 2;
	static const int buffer_length = 5 * extended_length;
	static const int search_position = 2 * extended_length;
	DSP::FastFourierTransform<symbol_length, cmplx, -1> fwd;
	SchmidlCox<float, cmplx, search_position, symbol_length, guard_length> correlator;
	DSP::BlockDC<float, float> block_dc;
	DSP::Hilbert<cmplx, filter_length> hilbert;
	DSP::BipBuffer<cmplx, buffer_length> buffer;
	DSP::Phasor<cmplx> osc;
	CODE::SimplexDecoder<6> simplex;
	CODE::ReverseFisherYatesShuffle<code_len> shuffle;
	PolarDecoder<code_type> polar;
	cmplx temp[extended_length], freq[symbol_length], prev[subcarrier_count], cons[subcarrier_count];
	code_type code[code_len], meta[meta_len];
	int symbol_number = payload_symbols;
	int symbol_position = search_position;
	int stored_position = 0;
	int staged_position = 0;
	int accumulated = 0;
	float stored_cfo_rad = 0;
	float staged_cfo_rad = 0;
	bool stored_check = false;
	bool staged_check = false;
	const cmplx *buf;

	static int bin(int carrier)
	{
		return (carrier + first_subcarrier + symbol_length) % symbol_length;
	}

	static int nrz(bool bit) {
		return 1 - 2 * bit;
	}

	static cmplx demod_or_erase(cmplx curr, cmplx prev) {
		if (norm(prev) <= 0)
			return 0;
		cmplx cons = curr / prev;
		if (norm(cons) > 4)
			return 0;
		return cons;
	}

	const cmplx *corSeq() {
		CODE::MLS seq(0b1100111);
		for (int i = 0; i < symbol_length; ++i)
			freq[i] = 0;
		for (int i = 1; i < subcarrier_count; ++i)
			freq[bin(i)] = nrz(seq());
		return freq;
	}

	cmplx analytic(float real) {
		return hilbert(block_dc(real));
	}

	float precision() {
		float sp = 0, np = 0;
		for (int i = 0; i < subcarrier_count; ++i) {
			code_type tmp[2];
			qpsk::hard(tmp, cons[i]);
			cmplx hard = qpsk::map(tmp);
			cmplx error = cons[i] - hard;
			sp += norm(hard);
			np += norm(error);
		}
		return sp / np;
	}

	void demap() {
		float pre = precision();
		for (int i = 0; i < subcarrier_count; ++i)
			qpsk::soft(code + 2 * (symbol_number * subcarrier_count + i), cons[i], pre);
	}

	int preamble() {
		DSP::Phasor<cmplx> nco;
		nco.omega(-staged_cfo_rad);
		for (int i = 0; i < symbol_length; ++i)
			temp[i] = buf[staged_position + extended_length + i] * nco();
		fwd(freq, temp);
		for (int i = 0; i < meta_len; ++i)
			cons[i] = demod_or_erase(freq[bin(i+1)], freq[bin(i)]);
		for (int i = 0; i < meta_len; ++i)
			bpsk::soft(meta + i, cons[i], 8);
		CODE::MLS seq(0b1000011);
		for (int i = 0; i < meta_len; ++i)
			meta[i] *= nrz(seq());
		return simplex(meta);
	}

	bool process() {
		if (staged_check) {
			staged_check = false;
			if (preamble() == 1) {
				osc.omega(-staged_cfo_rad);
				symbol_position = staged_position;
				symbol_number = -1;
				return false;
			}
		}
		bool fetch_payload = false;
		if (symbol_number < payload_symbols) {
			for (int i = 0; i < extended_length; ++i)
				temp[i] = buf[symbol_position + i] * osc();
			fwd(freq, temp);
			if (symbol_number >= 0) {
				for (int i = 0; i < subcarrier_count; ++i)
					cons[i] = demod_or_erase(freq[bin(i)], prev[i]);
				demap();
			}
			if (++symbol_number == payload_symbols)
				fetch_payload = true;
			for (int i = 0; i < subcarrier_count; ++i)
				prev[i] = freq[bin(i)];
		}
		return fetch_payload;
	}

public:
	Decoder() : correlator(corSeq()) {
		block_dc.samples(filter_length);
	}

	int fetch(uint8_t *payload) {
		shuffle(code);
		int result = polar(payload, code);
		CODE::Xorshift32 scrambler;
		for (int i = 0; i < mesg_bytes; ++i)
			payload[i] ^= scrambler();
		return result;
	}

	bool feed(const float *audio_buffer, int sample_count) {
		assert(sample_count <= extended_length);
		for (int i = 0; i < sample_count; ++i) {
			if (correlator(buffer(analytic(audio_buffer[i])))) {
				stored_cfo_rad = correlator.cfo_rad;
				stored_position = correlator.symbol_pos + accumulated - extended_length;
				stored_check = true;
			}
			if (++accumulated == extended_length)
				buf = buffer();
		}
		if (accumulated >= extended_length) {
			accumulated -= extended_length;
			if (stored_check) {
				staged_cfo_rad = stored_cfo_rad;
				staged_position = stored_position;
				staged_check = true;
				stored_check = false;
			}
			return process();
		}
		return false;
	}
};

