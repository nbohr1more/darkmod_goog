/*****************************************************************************
The Dark Mod GPL Source Code

This file is part of the The Dark Mod Source Code, originally based
on the Doom 3 GPL Source Code as published in 2011.

The Dark Mod Source Code is free software: you can redistribute it
and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation, either version 3 of the License,
or (at your option) any later version. For details, see LICENSE.TXT.

Project: The Dark Mod (http://www.thedarkmod.com/)

******************************************************************************/

#include "precompiled.h"
#include "renderer/backend/stages/ShadowMapStage.h"
#include "renderer/backend/RenderBackend.h"
#include "renderer/backend/FrameBuffer.h"
#include "renderer/backend/FrameBufferManager.h"
#include "renderer/backend/GLSLUniforms.h"
#include "renderer/backend/GLSLProgramManager.h"

idCVarBool r_shadowMapCullFront(
	"r_shadowMapCullFront", "0", CVAR_ARCHIVE | CVAR_RENDERER,
	"Cull front faces in shadow maps"
);
idCVar r_shadowMapCullFrontErode(
	"r_shadowMapCullFrontErode", "0", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_INTEGER,
	"With r_shadowMapCullFront: close one-texel light leaks at geometry seams by using the nearest depth of neighboring shadow map texels.\n"
	"0 - off, 1 - 2x2 texels, 2 - 4x4 texels, 3 - 8x8 texels (slow, for diagnostics)",
	0, 3, idCmdSystem::ArgCompletion_Integer<0, 3>
);
idCVar r_shadowMapCullFrontErodeCrease(
	"r_shadowMapCullFrontErodeCrease", "0", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_INTEGER,
	"With r_shadowMapCullFront and r_ssao enabled: erode level used only in creases (where SSAO is strong), where the light leaks appear.\n"
	"Same values as r_shadowMapCullFrontErode (the larger of the two is used). 0 - off.\n"
	"Much cheaper than using a high r_shadowMapCullFrontErode everywhere.",
	0, 3, idCmdSystem::ArgCompletion_Integer<0, 3>
);
idCVar r_shadowMapCullFrontSsaoLeakNear(
	"r_shadowMapCullFrontSsaoLeakNear", "300", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFrontSsaoLeak and r_shadowMapCullFrontErodeCrease: they are fully applied within this distance of the player (world units),\n"
	"then fade out smoothly to nothing at r_shadowMapCullFrontSsaoLeakDist.",
	0.0f, 100000.0f
);
idCVar r_shadowMapCullFrontSsaoLeakDist(
	"r_shadowMapCullFrontSsaoLeakDist", "1200", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"Distance from the player (world units) at which r_shadowMapCullFrontSsaoLeak and r_shadowMapCullFrontErodeCrease are fully faded out and skipped. 0 - no limit.",
	0.0f, 100000.0f
);
idCVar r_shadowMapCullFrontSsaoLeak(
	"r_shadowMapCullFrontSsaoLeak", "0", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFront and r_ssao enabled: darken light leaks in creases using the SSAO texture.\n"
	"0 - off, 1 - full strength. Works best with soft shadows (r_softShadowsQuality > 0).",
	0.0f, 1.0f
);
idCVar r_shadowMapCullFrontSsaoLeakRadius(
	"r_shadowMapCullFrontSsaoLeakRadius", "2", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFrontSsaoLeak: distance in pixels at which the neighbors are tested for being shadowed.\n"
	"A lit pixel with shadowed neighbors on both opposite sides within this distance is treated as light leak.\n"
	"Should be at least the width of the leak lines on screen, but small enough not to kill real thin lit areas.",
	0.5f, 8.0f
);
idCVar r_shadowMapCullFrontSsaoLeakMode(
	"r_shadowMapCullFrontSsaoLeakMode", "0", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_INTEGER,
	"With r_shadowMapCullFrontSsaoLeak: how thin lit lines (light leaks) are detected:\n"
	"0 - two pairs of opposite neighbors along screen axes, at r_shadowMapCullFrontSsaoLeakRadius pixels\n"
	"1 - ring of 8 neighbors: if at most 2 are lit, the pixel is a thin lit feature; it is confirmed to be a line by sampling further along its direction (and beside it).\n"
	"    The radius follows the size of shadow map texels on screen, see r_shadowMapCullFrontSsaoLeakTexels",
	0, 1, idCmdSystem::ArgCompletion_Integer<0, 1>
);
idCVar r_shadowMapCullFrontSsaoLeakTexels(
	"r_shadowMapCullFrontSsaoLeakTexels", "2", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFrontSsaoLeakMode 1: radius of the leak detector in shadow map texels, it is converted to screen pixels for every pixel.\n"
	"A leak is about one shadow texel wide, which is many pixels on screen where the shadow map is coarse (large or far lights), so a fixed radius in pixels is not enough there.\n"
	"The result is limited by r_shadowMapCullFrontSsaoLeakRadius (minimum, pixels) and r_shadowMapCullFrontSsaoLeakMaxRadius (maximum, pixels).",
	0.5f, 16.0f
);
idCVar r_shadowMapCullFrontSsaoLeakMaxRadius(
	"r_shadowMapCullFrontSsaoLeakMaxRadius", "10", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFrontSsaoLeakMode 1: the detector radius never exceeds this many pixels (neighbors are taken on the plane of the surface, so far neighbors may be off the surface).",
	1.0f, 32.0f
);
idCVar r_shadowMapCullFrontSsaoLeakMin(
	"r_shadowMapCullFrontSsaoLeakMin", "1", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With cull-front shadow maps and SSAO enabled: the shadow coefficient of a pixel is never brighter than its ambient occlusion term, min(shadow, ao).\n"
	"Leaks in creases are lit pixels where SSAO is dark, so this hides them regardless of how they are detected.\n"
	"The value is the strength (0 = off, 1 = full), it fades out with the distance like the other leak fixes (r_shadowMapCullFrontSsaoLeakNear / Dist).",
	0.0f, 1.0f
);
idCVar r_shadowMapContact(
	"r_shadowMapContact", "1", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"Shadow maps: screen-space contact shadows. A ray is marched from every lit pixel towards the light through the depth buffer, and if a visible surface is found in the way, the pixel is shadowed.\n"
	"This corrects light leaks which the shadow map itself cannot (it can only add shadow). The value is the strength (0 = off). Fades out with the distance like r_shadowMapCullFrontSsaoLeak (Near / Dist).",
	0.0f, 1.0f
);
idCVar r_shadowMapContactDist(
	"r_shadowMapContactDist", "24", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"r_shadowMapContact: length of the ray in world units. Leaks are found only if the occluder is within this distance from the pixel.",
	2.0f, 200.0f
);
idCVar r_shadowMapContactBlur(
	"r_shadowMapContactBlur", "1.5", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"r_shadowMapContact: radius (world units) of the blur of the contact occlusion along the surface. Softens halo edges, costs 5 marches with half the steps each. 0 = off.",
	0.0f, 16.0f
);
idCVar r_shadowMapContactBlurDark(
	"r_shadowMapContactBlurDark", "2", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"r_shadowMapContactBlur: weight of the darkest blur sample against the average of all (weight 1). 2 = leans dark 2 to 1, 0 = plain average.",
	0.0f, 8.0f
);
idCVar r_shadowMapContactThickness(
	"r_shadowMapContactThickness", "1.5", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"r_shadowMapContact: assumed thickness (world units, grows with distance from camera) of any visible surface. A ray passing behind it by more than this is not blocked. Lower removes halos around small objects, higher seals thicker leaks.",
	0.2f, 16.0f
);
idCVar r_shadowMapContactCreaseMode(
	"r_shadowMapContactCreaseMode", "2", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_INTEGER,
	"r_shadowMapContact: where to march. 0 - everywhere, 1 - only in dark SSAO (needs SSAO), 2 - only in creases measured from the depth buffer (no SSAO needed).",
	0, 2
);
idCVar r_shadowMapContactCreaseRadius(
	"r_shadowMapContactCreaseRadius", "4", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"r_shadowMapContactCreaseMode 2: radius in world units of the ring around the pixel which is searched for surfaces in front of it.",
	0.5f, 32.0f
);
idCVar r_shadowMapContactCreaseAo(
	"r_shadowMapContactCreaseAo", "0.9", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"r_shadowMapContact: only march in creases. SSAO value below this - 0.2 is a full crease, above it is skipped (needs SSAO). 0 = march everywhere.",
	0.0f, 1.0f
);
idCVar r_shadowMapContactSteps(
	"r_shadowMapContactSteps", "10", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_INTEGER,
	"r_shadowMapContact: number of depth buffer samples along the ray (cost per lit pixel).",
	2, 32
);
idCVarBool r_shadowMapContactSkipNoSelfShadow(
	"r_shadowMapContactSkipNoSelfShadow", "1", CVAR_ARCHIVE | CVAR_RENDERER,
	"r_shadowMapContact: do not apply the contact march to surfaces with noSelfShadow (they cannot be told apart as blockers, but are not darkened themselves)."
);
idCVar r_shadowMapCullFrontBiasSlope(
	"r_shadowMapCullFrontBiasSlope", "0", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFront: slope-scaled bias factor for shadow map depth (emulates polygon offset factor, in linear distance).\n"
	"Positive moves stored surfaces towards the light (more shadow at contact), negative moves them away. 0 - off.",
	-8.0f, 8.0f
);
idCVar r_shadowMapCullFrontBiasClamp(
	"r_shadowMapCullFrontBiasClamp", "2", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFrontBiasSlope: maximum slope-dependent bias in world units (emulates glPolygonOffsetClamp).",
	0.0f, 64.0f
);
idCVar r_shadowMapCullFrontBiasUnits(
	"r_shadowMapCullFrontBiasUnits", "0", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFront: constant bias of shadow map depth in world units. Positive moves stored surfaces towards the light. 0 - off.",
	-8.0f, 8.0f
);
idCVar r_shadowMapCullFrontExpand(
	"r_shadowMapCullFrontExpand", "0", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFront: grow shadow casters by this many shadow map texels when they are rendered into shadow maps (uses geometry shader).\n"
	"This closes light leaks at seams of casters, like r_shadowMapCullFrontErode does, but much cheaper since it is paid at rendering of the shadow map.\n"
	"Try 2-4. 0 - off.",
	0.0f, 8.0f
);
idCVar r_shadowMapCullFrontExpandDist(
	"r_shadowMapCullFrontExpandDist", "1200", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFrontExpand: only lights whose volume reaches within this distance of the player (world units) get expanded shadow casters.\n"
	"Light leaks of faraway lights are small on screen, and expansion has some cost. 0 - no limit.",
	0.0f, 100000.0f
);
idCVar r_shadowMapCullFrontExpandNear(
	"r_shadowMapCullFrontExpandNear", "300", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_FLOAT,
	"With r_shadowMapCullFrontExpand and r_shadowMapCullFrontExpandDist: casters closer than this to the player (world units) are expanded fully,\n"
	"then the expansion fades out smoothly to nothing at r_shadowMapCullFrontExpandDist.",
	0.0f, 100000.0f
);
idCVar r_shadowMapDebug(
	"r_shadowMapDebug", "0", CVAR_RENDERER | CVAR_INTEGER,
	"Debug views of shadow map lighting (colors of lights are added, so use a single light):\n"
	"0 - off\n"
	"1 - final shadow coefficient\n"
	"2 - decision of the central sample: black = shadow, white = lit, magenta = lit because shadow map texel is empty, red = lit but within error margin\n"
	"3 - effect of r_shadowMapCullFrontErode on hard shadows: red = lit turned into shadow\n"
	"4 - SSAO leak fix: red = crease, green = thin lit line detected, blue = final shadow\n"
	"5 - error margin in shadow map texels (white = 50)",
	0, 5, idCmdSystem::ArgCompletion_Integer<0, 5>
);
idCVar r_shadowMapSinglePass(
	"r_shadowMapSinglePass", "1", CVAR_ARCHIVE | CVAR_RENDERER | CVAR_BOOL,
	"1 - render shadow maps for all lights in a single pass"
);
idCVar r_shadowMapAlphaTested(
	"r_shadowMapAlphaTested", "1", CVAR_BOOL | CVAR_RENDERER | CVAR_ARCHIVE,
	"In case of alpha-tested material, apply alpha test to shadows too?\n"
	"Note: stencil shadows cannot work with alpha test."
);


struct ShadowMapStage::Uniforms : GLSLUniformGroup {
	UNIFORM_GROUP_DEF( Uniforms )
	DEFINE_UNIFORM( mat4, modelMatrix )
	DEFINE_UNIFORM( vec4, lightOrigin )
	DEFINE_UNIFORM( float, maxLightDistance )
	DEFINE_UNIFORM( float, alphaTest )
	DEFINE_UNIFORM( sampler, opaqueTexture )
	DEFINE_UNIFORM( mat4, textureMatrix )
	DEFINE_UNIFORM( vec3, depthBias )
	DEFINE_UNIFORM( vec2, expandNdc )
	DEFINE_UNIFORM( vec3, viewOrigin )
	DEFINE_UNIFORM( vec2, expandFalloff )
};

ShadowMapStage::ShadowMapStage() {}

void ShadowMapStage::Init() {
	shadowMapShader = programManager->LoadFromFiles( "shadow_map", "stages/shadow_map/shadow_map.vert.glsl", "stages/shadow_map/shadow_map.frag.glsl" );
	shadowMapBiasShader = programManager->LoadFromFiles( "shadow_map_bias", "stages/shadow_map/shadow_map.vert.glsl", "stages/shadow_map/shadow_map_bias.frag.glsl" );
	// variants with geometry shader which expands casters (r_shadowMapCullFrontExpand)
	idHashMapDict gsDefines;
	gsDefines.Set( "SHADOW_MAP_GS", "1" );
	shadowMapExpandShader = programManager->LoadFromFiles( "shadow_map_expand", "stages/shadow_map/shadow_map.vert.glsl", "stages/shadow_map/shadow_map.frag.glsl", "stages/shadow_map/shadow_map_expand.geom.glsl", gsDefines );
	shadowMapExpandBiasShader = programManager->LoadFromFiles( "shadow_map_expand_bias", "stages/shadow_map/shadow_map.vert.glsl", "stages/shadow_map/shadow_map_bias.frag.glsl", "stages/shadow_map/shadow_map_expand.geom.glsl", gsDefines );
}

void ShadowMapStage::Shutdown() {}

void ShadowMapStage::Start( const viewDef_t *viewDef ) {
	GL_CheckErrors();
	frameBuffers->EnterShadowMap();

	GL_Cull( r_shadowMapCullFront ? CT_BACK_SIDED : CT_TWO_SIDED );
	qglPolygonOffset( 0, 0 );
	qglEnable( GL_POLYGON_OFFSET_FILL );
	for ( int i = 0; i < 5; i++ ) {
		qglEnable( GL_CLIP_DISTANCE0 + i );
	}

	// the variant with depth bias writes gl_FragDepth, so it is used only when the bias is enabled
	float biasSlope = r_shadowMapCullFrontBiasSlope.GetFloat();
	float biasUnits = r_shadowMapCullFrontBiasUnits.GetFloat();
	bool useBias = r_shadowMapCullFront && ( biasSlope != 0.0f || biasUnits != 0.0f );
	// the variant with geometry shader grows casters, it is used only when expansion is enabled
	expandTexels = r_shadowMapCullFront ? r_shadowMapCullFrontExpand.GetFloat() : 0.0f;
	bool useExpand = expandTexels > 0.0f;
	// choose programs: plain one and (if enabled) the one with geometry shader, which is used only for lights close to the player
	biasParams = idVec3( biasSlope, r_shadowMapCullFrontBiasClamp.GetFloat(), biasUnits );
	usesBias = useBias;
	plainProgram = useBias ? shadowMapBiasShader : shadowMapShader;
	expandProgram = useExpand ? ( useBias ? shadowMapExpandBiasShader : shadowMapExpandShader ) : nullptr;
	expandDistance = r_shadowMapCullFrontExpandDist.GetFloat();
	viewOrigin = viewDef->renderView.vieworg;
	activeProgram = nullptr;
	SwitchProgram( plainProgram );
}

void ShadowMapStage::SwitchProgram( GLSLProgram *program ) {
	if ( program == activeProgram )
		return;
	activeProgram = program;
	program->Activate();
	uniforms = program->GetUniformGroup<Uniforms>();
	uniforms->opaqueTexture.Set( 0 );
	if ( usesBias )
		uniforms->depthBias.Set( biasParams.x, biasParams.y, biasParams.z );
}

bool ShadowMapStage::ShouldDrawLight( const viewLight_t *vLight, const DrawMask &mask ) {
	if ( vLight->noShadows ) {
		return false;
	}
	if ( mask.alpha ) {
		return vLight->shadows == LS_STENCIL && vLight->alphaShadowPage.width > 0 &&
			( mask.clear || mask.global && vLight->alphaShadows || mask.local && vLight->alphaLocalShadows );
	}
	if ( vLight->shadows != LS_MAPS) {
		return false;
	}
	if ( vLight->shadowMapPage.width == 0 ) {
		return false;
	}
	if ( !( mask.clear || mask.global && vLight->globalShadows || mask.local && vLight->localShadows ) ) {
		return false;
	}
	return true;
}

void ShadowMapStage::DrawLight( const viewLight_t *vLight, const DrawMask &mask ) {
	// expand casters only for lights which can affect what is near the player
	bool expand = false;
	if ( expandProgram && !mask.alpha ) {
		expand = true;
		if ( expandDistance > 0.0f ) {
			float distToLightVolume = ( vLight->globalLightOrigin - viewOrigin ).Length() - vLight->maxLightDistance;
			expand = distToLightVolume < expandDistance;
		}
	}
	SwitchProgram( expand ? expandProgram : plainProgram );
	if ( mask.alpha ) {
		// thin alpha cards: front and back are the same depth, so cull-front would make them shadow themselves completely
		GL_Cull( CT_TWO_SIDED );
	} else {
		GL_Cull( r_shadowMapCullFront ? CT_BACK_SIDED : CT_TWO_SIDED );
	}

	idVec4 lightOrigin;
	lightOrigin.x = vLight->globalLightOrigin.x;
	lightOrigin.y = vLight->globalLightOrigin.y;
	lightOrigin.z = vLight->globalLightOrigin.z;
	lightOrigin.w = 0;
	uniforms->lightOrigin.Set( lightOrigin );
	uniforms->maxLightDistance.Set( vLight->maxLightDistance );

	const renderCrop_t &page = mask.alpha ? vLight->alphaShadowPage : vLight->shadowMapPage;
	qglViewport( page.x, page.y, 6*page.width, page.width );
	// note: scissor must be always applied for correctness, also it is not view-dependent
	qglScissor( page.x, page.y, 6*page.width, page.width );
	if ( expand ) {
		// the viewport is 6 faces wide, NDC range is 2 in both directions
		uniforms->expandNdc.Set( expandTexels * 2.0f / ( 6 * page.width ), expandTexels * 2.0f / page.width );
		uniforms->viewOrigin.Set( viewOrigin );
		float fadeEnd = expandDistance;
		float fadeStart = fadeEnd > 0.0f ? idMath::Fmin( r_shadowMapCullFrontExpandNear.GetFloat(), fadeEnd * 0.99f ) : 0.0f;
		uniforms->expandFalloff.Set( fadeStart, fadeEnd );
	}

	if ( mask.clear )
		qglClear( GL_DEPTH_BUFFER_BIT );

	if ( mask.global )
		DrawLightInteractions( mask.alpha ? vLight->alphaShadows : vLight->globalShadows );

	if ( mask.local )
		DrawLightInteractions( mask.alpha ? vLight->alphaLocalShadows : vLight->localShadows );
}

void ShadowMapStage::End() {
	for ( int i = 0; i < 5; i++ ) {
		qglDisable( GL_CLIP_DISTANCE0 + i );
	}

	qglDisable( GL_POLYGON_OFFSET_FILL );
	GL_Cull( CT_FRONT_SIDED );

	frameBuffers->LeaveShadowMap();
}

bool ShadowMapStage::DrawShadowMapSingleLight( const viewDef_t *viewDef, const viewLight_t *vLight, const DrawMask &mask ) {
	if ( !ShouldDrawLight( vLight, mask ) )
		return false;

	TRACE_GL_SCOPE( "DrawShadowMapSingleLight" );

	Start( viewDef );
	DrawLight( vLight, mask );
	End();

	return true;
}

void ShadowMapStage::DrawShadowMapAllLights( const viewDef_t *viewDef, const DrawMask &mask ) {
	TRACE_GL_SCOPE( "DrawShadowMapAllLights" );

	Start( viewDef );
	for ( viewLight_t *vLight = viewDef->viewLights; vLight; vLight = vLight->next ) {
		if ( !ShouldDrawLight( vLight, mask ) )
			continue;
		DrawLight( vLight, mask );
	}
	End();
}

bool ShadowMapStage::ShouldDrawSurf( const drawSurf_t *surf ) const {
    const idMaterial *shader = surf->material;

    // some deforms may disable themselves by setting numIndexes = 0
    if ( !surf->numIndexes ) {
        return false;
    }

    if ( !surf->ambientCache.IsValid() || !surf->indexCache.IsValid() ) {
        #ifdef _DEBUG
        common->Printf( "ShadowMapStage: missing vertex or index cache\n" );
        #endif
        return false;
    }

	// #6571. parallax surfaces with this flag don't work well if the surface is rendered to shadow maps
	if ( auto parallaxStage = surf->material->GetParallaxStage() ) {
		if ( parallaxStage->parallax->offsetExternalShadows )
			return false;
	}

	return true;
}

void ShadowMapStage::DrawLightInteractions( const drawSurf_t *surfs ) {
	for ( const drawSurf_t *surf = surfs; surf; surf = surf->nextOnLight ) {
		if ( !ShouldDrawSurf( surf ) ) {
			continue;
		}
		DrawSurf( surf );
	}
}

void ShadowMapStage::DrawSurf( const drawSurf_t *surf ) {
	const idMaterial *shader = surf->material;

	vertexCache.VertexPosition( surf->ambientCache );

	bool drawSolid = false;

	if ( shader->Coverage() == MC_OPAQUE || shader->Coverage() == MC_TRANSLUCENT ) {
		drawSolid = true;
	}

	// we may have multiple alpha tested stages
	if ( shader->Coverage() == MC_PERFORATED ) {

		if ( r_shadowMapAlphaTested.GetBool() ) {
			// if the only alpha tested stages are condition register omitted,
			// draw a normal opaque surface
			bool	didDraw = false;

			GL_CheckErrors();

			// perforated surfaces may have multiple alpha tested stages
			for ( int stage = 0; stage < shader->GetNumStages(); stage++ ) {
				const shaderStage_t *pStage = shader->GetStage( stage );

				if ( !pStage->hasAlphaTest ) {
					continue;
				}

				// check the stage enable condition
				if ( !surf->IsStageEnabled( pStage ) ) {
					continue;
				}

				// if we at least tried to draw an alpha tested stage,
				// we won't draw the opaque surface
				didDraw = true;

				// skip the entire stage if alpha would be black
				if ( surf->GetStageColor( pStage )[3] <= 0 ) {
					continue;
				}
				IssueDrawCommand( surf, pStage );
			}

			if ( !didDraw ) {
				drawSolid = true;
			}
		}
		else {
			drawSolid = true;
		}
	}

	if ( drawSolid ) {  // draw the entire surface solid
		IssueDrawCommand( surf, nullptr );
	}
}

void ShadowMapStage::IssueDrawCommand( const drawSurf_t *surf, const shaderStage_t *stage ) {
	if( stage ) {
		GL_SelectTexture( 0 );
		stage->texture.image->Bind();
	}

	uniforms->modelMatrix.Set( surf->space->modelMatrix );

	if( stage ) {
		// set the alpha modulate
		uniforms->alphaTest.Set( surf->shaderRegisters[stage->alphaTestRegister] );
		uniforms->textureMatrix.Set( surf->GetTextureMatrix( stage ) );
	}
	else {
		uniforms->alphaTest.Set( -1.0f );
	}

	RB_DrawElementsInstanced( surf, 6, DCK_SHADOW );
}
