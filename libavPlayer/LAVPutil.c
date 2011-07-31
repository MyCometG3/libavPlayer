/*
 *  LAVPutil.c.c
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/28.
 *  Copyright 2011 MyCometG3. All rights reserved.
 *
 */
/*
 This file is part of livavPlayer.
 
 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.
 
 SimplePlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with xvidEncoder; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include <assert.h>
#import <Accelerate/Accelerate.h>
#include "string.h"

#define ENABLEFASTER 1
#define USESIMD 1

// Utility to round up to a multiple of 16.
int roundUpToMultipleOf16( int n )
{
	if( 0 != ( n & 15 ) )
		n = ( n + 15 ) & ~15;
	return n;
}

// Util to convert planer YUV420 into chunky yuv422
// For bitmap transfer : AVFrame -> CVPixelBuffer.
void copy_planar_YUV420_to_2vuy(size_t width, size_t height, 
								uint8_t *baseAddr_y, size_t rowBytes_y, 
								uint8_t *baseAddr_u, size_t rowBytes_u, 
								uint8_t *baseAddr_v, size_t rowBytes_v, 
								uint8_t *baseAddr_2vuy, size_t rowBytes_2vuy)
{
	
	assert( !(width & 0x1 || height & 0x1) );	/* At least both x and y should be even value */
	
#if USESIMD		/* memalign hack */
	uint8_t* temp_yt_aligned = malloc(roundUpToMultipleOf16(rowBytes_y));
	uint8_t* temp_yb_aligned = malloc(roundUpToMultipleOf16(rowBytes_y));
	uint8_t* temp_u_aligned  = malloc(roundUpToMultipleOf16(rowBytes_u));
	uint8_t* temp_v_aligned  = malloc(roundUpToMultipleOf16(rowBytes_v));
#endif
	
	int y = 0;
	
	for (y = 0; y < height; y += 2) {
		
		int x=0;
		uint8_t *p2top, *p2bot, *pytop, *pybot, *pu, *pv;
		p2top = (  y) * rowBytes_2vuy + (uint8_t*)baseAddr_2vuy;
		p2bot = (1+y) * rowBytes_2vuy + (uint8_t*)baseAddr_2vuy;
		pytop = (  y) * rowBytes_y    + (uint8_t*)baseAddr_y;
		pybot = (1+y) * rowBytes_y    + (uint8_t*)baseAddr_y;
		pu =	(y/2) * rowBytes_u    + (uint8_t*)baseAddr_u;
		pv =	(y/2) * rowBytes_v    + (uint8_t*)baseAddr_v;
		
#if USESIMD		/* memalign hack */
		if( (uint64_t)pytop & 0xF ) { memcpy(temp_yt_aligned, pytop, rowBytes_y); pytop = temp_yt_aligned; }
		if( (uint64_t)pybot & 0xF ) { memcpy(temp_yb_aligned, pybot, rowBytes_y); pybot = temp_yb_aligned; }
		if( (uint64_t)pu    & 0xF ) { memcpy(temp_u_aligned , pu   , rowBytes_u); pu    = temp_u_aligned; }
		if( (uint64_t)pv    & 0xF ) { memcpy(temp_v_aligned , pv   , rowBytes_v); pv    = temp_v_aligned; }
#endif
		
#if ENABLEFASTER
#if USESIMD
		for( ; x <= width-32; x += 32 ) {			// process W32xH2 pixels concurrently
			vUInt8 u = _mm_loadu_si128((__m128i*)(x/2+pu)), v = _mm_loadu_si128((__m128i*)(x/2+pv));
			vUInt8 uv1 = _mm_unpackhi_epi8(u, v), uv0 = _mm_unpacklo_epi8(u, v);
			
			vUInt8 yt0 = _mm_loadu_si128((__m128i*)( 0+x+pytop)), yt1 = _mm_loadu_si128((__m128i*)(16+x+pytop));
			vUInt8 yb0 = _mm_loadu_si128((__m128i*)( 0+x+pybot)), yb1 = _mm_loadu_si128((__m128i*)(16+x+pybot));
			
			_mm_stream_si128((__m128i*)( 0+x*2+p2top), _mm_unpacklo_epi8(uv0, yt0) );	// Chunky top left high
			_mm_stream_si128((__m128i*)(16+x*2+p2top), _mm_unpackhi_epi8(uv0, yt0) );	// Chunky top left low
			_mm_stream_si128((__m128i*)(32+x*2+p2top), _mm_unpacklo_epi8(uv1, yt1) );	// Chunky top right high
			_mm_stream_si128((__m128i*)(48+x*2+p2top), _mm_unpackhi_epi8(uv1, yt1) );	// Chunky top right low
			_mm_stream_si128((__m128i*)( 0+x*2+p2bot), _mm_unpacklo_epi8(uv0, yb0) );	// Chunky bot left high
			_mm_stream_si128((__m128i*)(16+x*2+p2bot), _mm_unpackhi_epi8(uv0, yb0) );	// Chunky bot left low
			_mm_stream_si128((__m128i*)(32+x*2+p2bot), _mm_unpacklo_epi8(uv1, yb1) );	// Chunky bot right high
			_mm_stream_si128((__m128i*)(48+x*2+p2bot), _mm_unpackhi_epi8(uv1, yb1) );	// Chunky bot right low
			
		}	// for(x <= width-32)
		
		if( x == width ) continue;
		
		pytop += x;
		pybot += x;
		pu += x/2;
		pv += x/2;
		p2top += x*2;
		p2bot += x*2;
#endif	//USESIMD
		
		for (; x <= width-8; x += 8) {			// process W8xH2 pixels concurrently
			uint32_t* ptrA = (uint32_t*)&p2top[0];
			uint32_t* ptrB = (uint32_t*)&p2top[4];
			uint32_t* ptrC = (uint32_t*)&p2bot[0];
			uint32_t* ptrD = (uint32_t*)&p2bot[4];
			*ptrA = (pytop[1] << 24) + (pv[0] << 16) + (pytop[0] << 8) + pu[0];
			*ptrB = (pytop[3] << 24) + (pv[1] << 16) + (pytop[2] << 8) + pu[1];
			*ptrC = (pybot[1] << 24) + (pv[0] << 16) + (pybot[0] << 8) + pu[0];
			*ptrD = (pybot[3] << 24) + (pv[1] << 16) + (pybot[2] << 8) + pu[1];
			uint32_t* ptrE = (uint32_t*)&p2top[8];
			uint32_t* ptrF = (uint32_t*)&p2top[12];
			uint32_t* ptrG = (uint32_t*)&p2bot[8];
			uint32_t* ptrH = (uint32_t*)&p2bot[12];
			*ptrE = (pytop[5] << 24) + (pv[2] << 16) + (pytop[4] << 8) + pu[2];
			*ptrF = (pytop[7] << 24) + (pv[3] << 16) + (pytop[6] << 8) + pu[3];
			*ptrG = (pybot[5] << 24) + (pv[2] << 16) + (pybot[4] << 8) + pu[2];
			*ptrH = (pybot[7] << 24) + (pv[3] << 16) + (pybot[6] << 8) + pu[3];
			
			p2top += 16;
			p2bot += 16;
			pytop += 8;
			pybot += 8;
			pu += 4;
			pv += 4;
		}	// for(x <= width-8)
#endif	//ENABLEFASTER
		
		for (; x < width; x += 2) {
			/* 2vuy contains samples clustered Cb, Y0, Cr, Y1.  */
			// Convert a 2x2 block of pixels from 4 separate Y samples, 1 U and 1 V to two 2vuy pixel blocks.
			p2top[1] = pytop[0];
			p2top[3] = pytop[1];
			p2bot[1] = pybot[0];
			p2bot[3] = pybot[1];
			p2top[0] = pu[0];
			p2bot[0] = pu[0];
			p2top[2] = pv[0];
			p2bot[2] = pv[0];
			
			// Advance to the next 2x2 block of pixels.
			p2top += 4;
			p2bot += 4;
			pytop += 2;
			pybot += 2;
			pu += 1;
			pv += 1;
		}	// for(x <= width-2)
		
	}	// for(y < height)
	
#if USESIMD		/* memalign hack */
	free(temp_yt_aligned);
	free(temp_yb_aligned);
	free(temp_u_aligned);
	free(temp_v_aligned);
#endif
}
