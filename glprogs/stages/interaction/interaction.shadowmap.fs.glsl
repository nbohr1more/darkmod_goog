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
#version 330 core
#extension GL_ARB_texture_gather: enable
#extension GL_ARB_texture_query_lod: enable

#define STGATILOV_USEGATHER 1

out vec4 FragColor;

#pragma tdm_include "stages/interaction/interaction.common.fs.glsl"
#define TDM_allow_ARB_texture_gather STGATILOV_USEGATHER
#pragma tdm_include "tdm_shadowmaps.glsl"
#pragma tdm_include "tdm_shadowstencilsoft_ssabss.glsl"

uniform vec4 u_shadowRect;
uniform sampler2D u_shadowMap;
uniform sampler2D u_ssaoTexture;
uniform vec2 u_renderResolution;
uniform int u_shadowMapDebug;
uniform vec3 u_shadowMapSsaoLeak;	// (leak fix strength, neighbor distance in pixels, erode level used in creases)
uniform vec3 u_shadowMapSsaoLeakRange;	// mode 1: (radius in shadow map texels, min radius in pixels, max radius in pixels)
uniform float u_shadowMapSsaoLeakMin;	// strength of min(shadow, ao)
uniform int u_shadowMapSsaoLeakMode;	// 0 = opposite neighbors along axes, 1 = ring of neighbors + line check
uniform vec2 u_shadowMapSsaoFade;	// leak fix is full within x units from the viewer, fades out to nothing at y units (y = 0: no fading)
uniform vec3 u_globalViewOrigin;
uniform vec3 u_globalLightOrigin;
uniform sampler2D u_depthTexture;	// scene depth, for the contact ray march
uniform vec3 u_shadowMapContactCrease;	// (mode: 0 off, 1 SSAO, 2 depth buffer; SSAO threshold; ring radius in world units)
uniform vec2 u_shadowMapContactBlur;	// (radius of the occlusion blur on the surface in world units, 0 = off; weight of the darkest sample vs the mean)
uniform float u_shadowMapContactThickness;	// assumed thickness of visible surfaces, world units
uniform vec3 u_shadowMapContact;	// (strength, ray length in world units, number of steps)

in vec3 var_LightDirWorld;

int getErodeLevel() {
	if (checkFlag(u_flags, SFL_INTERACTION_SHADOW_MAP_ERODE_8X8))
		return 3;
	if (checkFlag(u_flags, SFL_INTERACTION_SHADOW_MAP_ERODE_4X4))
		return 2;
	return checkFlag(u_flags, SFL_INTERACTION_SHADOW_MAP_ERODE_2X2) ? 1 : 0;
}

// size of N shadow map texels at the fragment, measured in screen pixels
// (a leak is about one texel wide: if the shadow map is coarse compared to the screen, the line is many pixels wide)
float leakRadiusInPixels(vec3 dirToLight, vec3 dirDx, vec3 dirDy) {
	vec3 a = abs(dirToLight);
	float major = max(a.x, max(a.y, a.z));
	// the face spans 2 * major in the direction vector, and shadowRect.w * atlas width texels
	float faceTexels = u_shadowRect.w * float(textureSize(u_shadowMap, 0).x);
	float texelInDir = 2.0 * major / max(faceTexels, 1.0);
	float pixelInDir = sqrt(0.5 * (dot(dirDx, dirDx) + dot(dirDy, dirDy)));
	float pixels = u_shadowMapSsaoLeakRange.x * texelInDir / max(pixelInDir, 1e-6);
	return clamp(pixels, u_shadowMapSsaoLeakRange.y, u_shadowMapSsaoLeakRange.z);
}

// hard shadow (1 = shadowed, 0 = lit) at the point of the surface which is o pixels away from the current one on screen
float leakShadowAt(vec3 dirToLight, vec3 dirDx, vec3 dirDy, vec2 o, vec3 worldNormal, int erode) {
	return 1.0 - computeShadowMapCoefficient(dirToLight + dirDx * o.x + dirDy * o.y, worldNormal, u_shadowMap, u_shadowRect, 0, u_softShadowsRadius, true, erode);
}

// Detector of thin lit features (light leaks) around a lit pixel, independent of their direction. Returns 1 for a leak, 0 otherwise.
//   1. 8 points on a ring of radius R. A pixel inside a normally lit area (or at its edge) has 3 or more lit ring points.
//   2. no lit point at all: isolated lit speck => leak.
//   3. 1-2 lit points: the lit thing goes through the pixel in the direction of them. Check the point R further along that direction
//      and the points R to both sides of it: a line is dark on both sides, while a corner / tip of a lit area which widens is lit on one.
float detectThinLitFeature(vec3 dirToLight, vec3 dirDx, vec3 dirDy, float R, vec3 worldNormal, int erode) {
	const vec2 RING[8] = vec2[8](
		vec2(1.0, 0.0), vec2(0.7071, 0.7071), vec2(0.0, 1.0), vec2(-0.7071, 0.7071),
		vec2(-1.0, 0.0), vec2(-0.7071, -0.7071), vec2(0.0, -1.0), vec2(0.7071, -0.7071)
	);
	int litCount = 0;
	int firstLit = 0;
	vec2 litSum = vec2(0.0);
	for (int i = 0; i < 8; i++) {
		if (leakShadowAt(dirToLight, dirDx, dirDy, RING[i] * R, worldNormal, erode) < 0.5) {
			if (litCount == 0)
				firstLit = i;
			litCount++;
			litSum += RING[i];
			if (litCount > 2)
				return 0.0;		// wide lit area, stop sampling
		}
	}
	if (litCount == 0)
		return 1.0;
	// two opposite lit points cancel each other: the line goes along either of them
	vec2 d = dot(litSum, litSum) > 0.09 ? normalize(litSum) : RING[firstLit];
	vec2 p = d * (2.0 * R);
	vec2 side = vec2(-d.y, d.x) * R;
	bool wide = leakShadowAt(dirToLight, dirDx, dirDy, p + side, worldNormal, erode) < 0.5
		|| leakShadowAt(dirToLight, dirDx, dirDy, p - side, worldNormal, erode) < 0.5;
	return wide ? 0.0 : 1.0;
}

void main() {
	InteractionGeometry props;
	vec3 worldParallax;
	FragColor.rgb = computeInteraction(props, worldParallax);

	vec3 worldNormal = mat3(u_modelMatrix) * var_TangentBitangentNormalMatrix[2];
	if (props.localN.z < 0.0)	// #5862: reverse-sided material with Z < 0 normalmap
		worldNormal = -worldNormal;

	if (checkFlag(u_flags, SFL_INTERACTION_SHADOWS)) {
		vec3 dirToLight = -var_LightDirWorld;
		if (checkFlag(u_flags, SFL_INTERACTION_PARALLAX_OFFSET_EXTERNAL_SHADOWS))
			dirToLight += worldParallax;
		// light vector changes linearly over the surface: derivatives give neighbor pixels on the same plane
		// (must be computed in uniform control flow)
		vec3 dirToLightDx = dFdx(dirToLight);
		vec3 dirToLightDy = dFdy(dirToLight);
		// stage 1: shadow with the global erode level (uniform for the whole draw call)
		int erodeLevel = getErodeLevel();
		bool cullFrontMode = checkFlag(u_flags, SFL_INTERACTION_SHADOW_MAP_CULL_FRONT);
		float shadowsCoeff = computeShadowMapCoefficient(
			dirToLight, worldNormal,
			u_shadowMap, u_shadowRect,
			u_softShadowsQuality, u_softShadowsRadius,
			cullFrontMode, erodeLevel
		);
		// stage 2: leaks appear in creases (SSAO is strong there), so use stronger erode there.
		// Erode can only remove light, so pixels which are already fully shadowed are skipped: the result would be the same.
		// the leak fixes are applied only near the viewer, with smooth fade out: they are expensive and leaks are small far away
		float ssaoFade = 0.0;
		if (checkFlag(u_flags, SFL_INTERACTION_SHADOW_MAP_SSAO_LEAK)) {
			ssaoFade = 1.0;
			if (u_shadowMapSsaoFade.y > 0.0) {
				// world position of the fragment is: u_globalLightOrigin - var_LightDirWorld
				float viewDist = length(u_globalViewOrigin - u_globalLightOrigin + var_LightDirWorld);
				ssaoFade = 1.0 - smoothstep(u_shadowMapSsaoFade.x, u_shadowMapSsaoFade.y, viewDist);
			}
		}
		float ssaoCrease = 0.0;
		float ao = 1.0;
		if (ssaoFade > 0.01) {
			ao = texture(u_ssaoTexture, gl_FragCoord.xy / u_renderResolution).r;
			ssaoCrease = 1.0 - smoothstep(0.6, 0.95, ao);
			int creaseLevel = int(u_shadowMapSsaoLeak.z + 0.5);
			// erode level is discrete: it is reduced step by step while fading out
			creaseLevel = ssaoFade > 0.66 ? creaseLevel : (ssaoFade > 0.33 ? min(creaseLevel, 2) : min(creaseLevel, 1));
			if (ssaoCrease > 0.25 && creaseLevel > erodeLevel && shadowsCoeff > 0.001) {
				erodeLevel = creaseLevel;
				shadowsCoeff = computeShadowMapCoefficient(
					dirToLight, worldNormal,
					u_shadowMap, u_shadowRect,
					u_softShadowsQuality, u_softShadowsRadius,
					cullFrontMode, erodeLevel
				);
			}
		}
		float dbgCrease = 0.0, dbgThinLine = 0.0;
		if (ssaoFade > 0.01) {
			// Cull-front shadow maps leak light in thin lit lines along creases / seams of geometry.
			// A leak is a lit pixel with shadowed pixels on both sides of it.
			// So: only in creases (SSAO is strong there) and only if the pixel is not already dark,
			// check the shadow at 4 neighbor points of the surface (+-R pixels along screen axes),
			// and if two opposite neighbors are both shadowed, then the pixel is a thin lit line => darken it.
			float crease = ssaoCrease;
			dbgCrease = crease;
			float k = u_shadowMapSsaoLeak.x * crease * ssaoFade;
			if (k > 0.01 && shadowsCoeff > 0.02) {
				vec3 stepX = dirToLightDx * u_shadowMapSsaoLeak.y;
				vec3 stepY = dirToLightDy * u_shadowMapSsaoLeak.y;
				int erode = erodeLevel;
				float thinLine;
				if (u_shadowMapSsaoLeakMode != 0) {
					float leakRadius = leakRadiusInPixels(dirToLight, dirToLightDx, dirToLightDy);
					thinLine = detectThinLitFeature(dirToLight, dirToLightDx, dirToLightDy, leakRadius, worldNormal, erode);
				} else {
					// hard (center only) shadow at neighbors: 1 means shadowed
					float dL = 1.0 - computeShadowMapCoefficient(dirToLight - stepX, worldNormal, u_shadowMap, u_shadowRect, 0, u_softShadowsRadius, true, erode);
					float dR = 1.0 - computeShadowMapCoefficient(dirToLight + stepX, worldNormal, u_shadowMap, u_shadowRect, 0, u_softShadowsRadius, true, erode);
					float dD = 1.0 - computeShadowMapCoefficient(dirToLight - stepY, worldNormal, u_shadowMap, u_shadowRect, 0, u_softShadowsRadius, true, erode);
					float dU = 1.0 - computeShadowMapCoefficient(dirToLight + stepY, worldNormal, u_shadowMap, u_shadowRect, 0, u_softShadowsRadius, true, erode);
					thinLine = max(dL * dR, dD * dU);
				}
				dbgThinLine = thinLine;
				shadowsCoeff *= 1.0 - k * thinLine;
			}
		}
		if (ssaoFade > 0.01 && u_shadowMapSsaoLeakMin > 0.0) {
			// light which leaked into a place where SSAO is dark: the pixel is never brighter than its ambient occlusion
			shadowsCoeff = min(shadowsCoeff, mix(1.0, ao, u_shadowMapSsaoLeakMin * ssaoFade));
		}
		if (checkFlag(u_flags, SFL_INTERACTION_SHADOW_MAP_CONTACT) && shadowsCoeff > 0.02) {
			// screen-space ray march towards the light: a surface which is visible and lies between the pixel and the light shadows it,
			// no matter what the shadow map says (it leaks in creases and seams). This can only darken.
			float contactFade = 1.0;
			if (u_shadowMapSsaoFade.y > 0.0) {
				float viewDist = length(u_globalViewOrigin - u_globalLightOrigin + var_LightDirWorld);
				contactFade = 1.0 - smoothstep(u_shadowMapSsaoFade.x, u_shadowMapSsaoFade.y, viewDist);
			}
			vec2 pixSize = 1.0 / u_renderResolution;
			vec3 P_v = viewPosFromUvDepth(u_projectionMatrix, gl_FragCoord.xy * pixSize, gl_FragCoord.z);
			mat3 mv3 = mat3(u_modelViewMatrix);
			vec3 N_v = normalize(mv3 * var_TangentBitangentNormalMatrix[2]);
			if (dot(N_v, -P_v) < 0.0)
				N_v = -N_v;
			float contactNoise = interleavedGradientNoise(gl_FragCoord.xy);
			if (u_shadowMapContactCrease.x > 1.5) {
				if (contactFade > 0.01)
					contactFade *= contactCreaseFactor(u_depthTexture, u_projectionMatrix, P_v, N_v, u_shadowMapContactCrease.z, contactNoise, 0.5 * pixSize, 1.0 - 0.5 * pixSize);
			} else if (u_shadowMapContactCrease.x > 0.5) {
				float aoC = texture(u_ssaoTexture, gl_FragCoord.xy / u_renderResolution).r;
				contactFade *= 1.0 - smoothstep(u_shadowMapContactCrease.y - 0.2, u_shadowMapContactCrease.y, aoC);
			}
			// a leak is a lit pixel right next to shadow: far from any shadow in the shadow map (e.g. around a candle
			// whose own geometry does not cast) the march only finds false blockers, so skip it there
			if (contactFade > 0.01 && shadowsCoeff > 0.98) {
				// soft count of shadowed taps (not a binary test): a pixel with two or more shadowed neighbors counts fully
				float nearShadow = 0.0;
				for (int ring = 0; ring < 2 && nearShadow < 1.0; ring++) {
					float R = ring == 0 ? 4.0 : 10.0;
					for (int i = 0; i < 8; i++) {
						float a = (float(i) + 0.5 * float(ring)) * 0.785398;
						nearShadow += leakShadowAt(dirToLight, dirToLightDx, dirToLightDy, vec2(cos(a), sin(a)) * R, worldNormal, erodeLevel) > 0.5 ? 0.5 : 0.0;
					}
				}
				nearShadow = smoothstep(0.0, 1.0, nearShadow);
				contactFade *= nearShadow;
			}
			if (contactFade > 0.01) {
				vec3 objectToLight = var_TangentBitangentNormalMatrix * var_LightDirLocal;
				vec3 lightPos_v = P_v + mv3 * objectToLight;
				float occlusion = ssabssContactOcclusionBlurred(
					u_depthTexture, u_projectionMatrix,
					P_v, N_v, lightPos_v, u_shadowMapContact.y, int(u_shadowMapContact.z + 0.5),
					contactNoise,
					0.5 * pixSize, 1.0 - 0.5 * pixSize, u_shadowMapContactThickness, u_shadowMapContactBlur.x, u_shadowMapContactBlur.y
				);
				shadowsCoeff = min(shadowsCoeff, 1.0 - u_shadowMapContact.x * contactFade * occlusion);
			}
		}
		if (u_shadowMapDebug == 0) {
			FragColor.rgb *= shadowsCoeff;
		} else {
			// debug views (r_shadowMapDebug): the color of each light is added, so look at one light at a time
			bool cullFront = checkFlag(u_flags, SFL_INTERACTION_SHADOW_MAP_CULL_FRONT);
			int erode = erodeLevel;
			vec3 dbg = vec3(shadowsCoeff);
			if (u_shadowMapDebug == 2) {
				// center sample decision: black = shadowed, white = lit, magenta = lit because shadow map texel is empty,
				// red = lit but within the error margin band (depth compare is ambiguous)
				float state = debugShadowMapCenter(dirToLight, worldNormal, u_shadowMap, u_shadowRect, cullFront).x;
				dbg = state < 0.5 ? vec3(0.0) : (state < 1.5 ? vec3(1.0) : (state < 2.5 ? vec3(1.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
			} else if (u_shadowMapDebug == 3) {
				// effect of r_shadowMapCullFrontErode on hard shadows: red = erode turned lit into shadowed, blue = the opposite
				float hardPlain = computeShadowMapCoefficient(dirToLight, worldNormal, u_shadowMap, u_shadowRect, 0, u_softShadowsRadius, cullFront, 0);
				float hardErode = computeShadowMapCoefficient(dirToLight, worldNormal, u_shadowMap, u_shadowRect, 0, u_softShadowsRadius, cullFront, erode);
				dbg = vec3(0.5 * hardErode);
				if (hardPlain > 0.5 && hardErode < 0.5)
					dbg = vec3(1.0, 0.0, 0.0);
				else if (hardPlain < 0.5 && hardErode > 0.5)
					dbg = vec3(0.0, 0.0, 1.0);
			} else if (u_shadowMapDebug == 4) {
				// SSAO leak fix: red = crease strength, green = thin lit line detected, blue = final shadow coefficient
				dbg = vec3(dbgCrease, dbgThinLine, shadowsCoeff);
			} else if (u_shadowMapDebug == 5) {
				// absolute error margin of depth compare in shadow map texels (white = 50 texels)
				dbg = vec3(debugShadowMapCenter(dirToLight, worldNormal, u_shadowMap, u_shadowRect, cullFront).y / 50.0);
			}
			FragColor.rgb = dbg;
		}
	}
	FragColor.a = 1.0;
}
