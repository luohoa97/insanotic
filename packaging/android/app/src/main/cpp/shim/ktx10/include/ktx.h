/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Stand-in for the Khronos libktx header that darkplaces' gl_textures.c
 * includes on Android for its ETC1 (.ktx) texture loader. libktx is not part
 * of the Insanotic tree and Xonotic ships no .ktx textures, so this declares
 * just the API the engine references and the loader always reports failure:
 * every .ktx lookup falls through to the normal tga/jpg/png loaders.
 */
#ifndef INSANOTIC_KTX_SHIM_H
#define INSANOTIC_KTX_SHIM_H

#include <SDL_opengles2.h>

typedef struct KTX_dimensions
{
	GLsizei width, height, depth;
} KTX_dimensions;

typedef enum KTX_error_code
{
	KTX_SUCCESS = 0,
	KTX_UNSUPPORTED_TEXTURE_TYPE = 11
} KTX_error_code;

static inline KTX_error_code ktxLoadTextureM(const void *bytes, GLsizei size,
	GLuint *pTexture, GLenum *pTarget, KTX_dimensions *pDimensions,
	GLboolean *pIsMipmapped, GLenum *pGlerror, GLuint *pKvdLen,
	GLubyte **ppKvd)
{
	(void)bytes; (void)size; (void)pTexture; (void)pDimensions;
	(void)pIsMipmapped; (void)pKvdLen; (void)ppKvd;
	if (pTarget)
		*pTarget = 0;
	if (pGlerror)
		*pGlerror = 0;
	return KTX_UNSUPPORTED_TEXTURE_TYPE;
}

#endif
