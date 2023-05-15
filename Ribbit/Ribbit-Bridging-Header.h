//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//
_Bool createEncoder();
_Bool createDecoder();
_Bool feedDecoder(const float *audioBuffer, int sampleCount);
int fetchDecoder(char *payload);
void initEncoder(const char *payload);
_Bool readEncoder(float *audioBuffer, int sampleCount);
