/*
C wrapper for C++ encoder and decoder

Copyright 2023 Ahmet Inan <inan@aicodix.de>
*/

#define assert(expr)
#include "encoder.hh"
#include "decoder.hh"

static Encoder *encoder;
static Decoder *decoder;

extern "C" bool createEncoder(int sampleRate) {
	if (encoder)
		return true;
	encoder = new(std::nothrow) Encoder();
	return encoder != nullptr;
}

extern "C" void destroyEncoder() {
	delete encoder;
	encoder = nullptr;
}

extern "C" bool readEncoder(float *audioBuffer, int sampleCount) {
	return encoder ? encoder->read(audioBuffer, sampleCount) : true;
}

extern "C" void initEncoder(const char *payload) {
	if (encoder != nullptr)
		encoder->init(reinterpret_cast<const uint8_t *>(payload));
}

extern "C" void destroyDecoder() {
	delete decoder;
	decoder = nullptr;
}

extern "C" bool createDecoder() {
	if (decoder)
		return true;
	decoder = new(std::nothrow) Decoder();
	return decoder != nullptr;
}

extern "C" int fetchDecoder(char *payload) {
	return decoder ? decoder->fetch(reinterpret_cast<uint8_t *>(payload)) : -1;
}

extern "C" bool feedDecoder(const float *audioBuffer, int sampleCount) {
	return decoder ? decoder->feed(audioBuffer, sampleCount) : false;
}
