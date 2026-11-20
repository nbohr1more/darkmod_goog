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

#pragma tdm_include "tdm_utils.glsl"
#pragma tdm_include "tdm_poissondisk.glsl"  // note: adds uniform

// 0 = legacy: the same Poisson pattern for every pixel, uniform weights
// 1 = the pattern is rotated by a per-pixel angle (bands become fine noise) and samples are weighted by a tent (smoother penumbra edge)
uniform float u_softShadowsFilter;

mat2 softShadowsPatternRotation() {
	if (u_softShadowsFilter < 0.5)
		return mat2(1.0, 0.0, 0.0, 1.0);
	vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
	float a = 6.2831853 * fract(magic.z * fract(dot(gl_FragCoord.xy, magic.xy)));
	float c = cos(a), s = sin(a);
	return mat2(c, s, -s, c);
}
float softShadowsSampleWeight(vec2 s) {
	return u_softShadowsFilter < 0.5 ? 1.0 : 1.0 - 0.6 * dot(s, s);
}

vec3 CubeMapDirectionToUv(vec3 v, out int faceIdx) {
	vec3 v1 = abs(v);
	float maxV = max(v1.x, max(v1.y, v1.z));
	faceIdx = 0;
	if(maxV == v.x) {
		v1 = -v.zyx;
	}
	else if(maxV == -v.x) {
		v1 = v.zyx * vec3(1, -1, 1);
		faceIdx = 1;
	}
	else if(maxV == v.y) {
		v1 = v.xzy * vec3(1, 1, -1);
		faceIdx = 2;
	}
	else if(maxV == -v.y) {
		v1 = v.xzy * vec3(1, -1, 1);
		faceIdx = 3;
	}
	else if(maxV == v.z) {
		v1 = v.xyz * vec3(1, -1, -1);
		faceIdx = 4;
	}
	else { //if(maxV == -v.z) {
		v1 = v.xyz * vec3(-1, -1, 1);
		faceIdx = 5;
	}
	v1.xy /= -v1.z;
	return v1;
}

//shadowRect defines where one face of this light is within the map atlas:
//  (offsetX, offsetY, ?, size)     (all from 0..1)
//lightVec is world-space vector from the light origin to the fragment being considered
//returns positive distance along face normal of cube map (i.e. along coordinate where lightVec has maximum absolute value)
float ShadowAtlasForVector(in sampler2D shadowMapTexture, vec4 shadowRect, vec3 lightVec) {
	int faceIdx;
	vec3 v1 = CubeMapDirectionToUv(lightVec, faceIdx);
	vec2 texSize = textureSize(shadowMapTexture, 0);
	vec2 shadow2d = (v1.xy * .5 + vec2(.5) ) * shadowRect.ww + shadowRect.xy;
	shadow2d.x += (shadowRect.w + 1./texSize.x) * faceIdx;
	float d = textureLod(shadowMapTexture, shadow2d, 0).r;
	return 1 / (1 - d);
}
#if TDM_allow_ARB_texture_gather
vec4 ShadowAtlasForVector4(in sampler2D shadowMapTexture, vec4 shadowRect, vec3 lightVec, out vec4 sampleWeights) {
	int faceIdx;
	vec3 v1 = CubeMapDirectionToUv(lightVec, faceIdx);
	vec2 texSize = textureSize(shadowMapTexture, 0);
	vec2 shadow2d = (v1.xy * .5 + vec2(.5) ) * shadowRect.ww + shadowRect.xy;
	shadow2d.x += (shadowRect.w + 1./texSize.x) * faceIdx;
#if GL_ARB_texture_gather
	vec4 d = textureGather(shadowMapTexture, shadow2d);
#else
	vec4 d = textureLod(shadowMapTexture, shadow2d, 0).rrrr;
#endif
	vec2 wgt = fract(shadow2d * texSize - 0.5);
	vec2 mwgt = vec2(1) - wgt;
	sampleWeights = vec4(mwgt.x, wgt.x, wgt.x, mwgt.x) * vec4(wgt.y, wgt.y, mwgt.y, mwgt.y);
	return vec4(1) / (vec4(1) - d);
}
#endif

// Returns the nearest blocker distance over a footprint of texels around the lookup point.
// erodeLevel: 0 = single bilinear-less fetch (like ShadowAtlasForVector), 1 = 2x2 texels, 2 = 4x4 texels, 3 = 8x8 texels.
// Used with cull-front shadow maps: a one-texel gap between back faces of adjacent casters
// holds far depth, which would let light leak through; taking the minimum depth closes such gaps.
float ShadowAtlasNearestForVector(in sampler2D shadowMapTexture, vec4 shadowRect, vec3 lightVec, int erodeLevel) {
#if TDM_allow_ARB_texture_gather && defined(GL_ARB_texture_gather)
	if (erodeLevel > 0) {
		int faceIdx;
		vec3 v1 = CubeMapDirectionToUv(lightVec, faceIdx);
		vec2 texSize = textureSize(shadowMapTexture, 0);
		vec2 shadow2d = (v1.xy * .5 + vec2(.5) ) * shadowRect.ww + shadowRect.xy;
		shadow2d.x += (shadowRect.w + 1./texSize.x) * faceIdx;
		vec2 t = 1.0 / texSize;
		vec2 faceMin = shadowRect.xy + vec2((shadowRect.w + t.x) * float(faceIdx), 0.0) + 0.55 * t;
		vec2 faceMax = shadowRect.xy + vec2((shadowRect.w + t.x) * float(faceIdx), 0.0) + vec2(shadowRect.w) - 0.55 * t;
		vec4 d = textureGather(shadowMapTexture, clamp(shadow2d, faceMin, faceMax));
		float m = min(min(d.x, d.y), min(d.z, d.w));
		// each gather covers 2x2 texels: 2x2 gathers = 4x4 texels (level 2), 4x4 gathers = 8x8 texels (level 3)
		// note: loop bounds are constants, so that the compiler can unroll them
		if (erodeLevel > 2) {
			for (int iy = -2; iy < 2; iy++) {
				for (int ix = -2; ix < 2; ix++) {
					vec2 uv = clamp(shadow2d + vec2(2 * ix + 1, 2 * iy + 1) * t, faceMin, faceMax);
					vec4 dd = textureGather(shadowMapTexture, uv);
					m = min(m, min(min(dd.x, dd.y), min(dd.z, dd.w)));
				}
			}
		} else if (erodeLevel > 1) {
			for (int iy = -1; iy < 1; iy++) {
				for (int ix = -1; ix < 1; ix++) {
					vec2 uv = clamp(shadow2d + vec2(2 * ix + 1, 2 * iy + 1) * t, faceMin, faceMax);
					vec4 dd = textureGather(shadowMapTexture, uv);
					m = min(m, min(min(dd.x, dd.y), min(dd.z, dd.w)));
				}
			}
		}
		return 1 / (1 - m);
	}
#endif
	return ShadowAtlasForVector(shadowMapTexture, shadowRect, lightVec);
}


float computeShadowMapCoefficient(
	vec3 worldFromLight, vec3 worldNormal,
	sampler2D shadowMap, vec4 shadowRect,
	int softQuality, float softRadius, bool shadowMapCullFrontHack, int erodeLevel
) {
	if (!shadowMapCullFrontHack)
		erodeLevel = 0;
	float shadowMapResolution = (textureSize(shadowMap, 0).x * shadowRect.w);

	//get unit direction from light to current fragment
	vec3 L = normalize(worldFromLight);
	//find maximum absolute coordinate in light vector
	vec3 absL = abs(worldFromLight);
	float maxAbsL = max(absL.x, max(absL.y, absL.z));

	//note: using different normal affects near-tangent lighting greatly
	float lightFallAngle = -dot(worldNormal, L);

	//note: choosing normal and how to cap angles is the hardest question for now
	//this has large effect on near-tangent surfaces (mostly the curved ones)
#ifdef SHADOWMAP_NO_FALL_ANGLE_LIMITER
	//thin alpha-tested casters: the receiver can be the caster itself, angle must not zero the light
	float fallAngleLimiter = 1.0;
#else
	float fallAngleLimiter = smoothstep(0.01, 0.05, lightFallAngle);
#endif
	//some very generic error estimation...
	float minFallAngle = shadowMapCullFrontHack ? 0.25 : 0.1;
	float errorMargin = 5.0 * maxAbsL / ( shadowMapResolution * max(lightFallAngle, minFallAngle) );
	if (shadowMapCullFrontHack)
	   errorMargin *= -.5;

	//process central shadow sample
	float centerFragZ = maxAbsL;
#if STGATILOV_USEGATHER && defined(GL_ARB_texture_gather)
	float lit;
	if (erodeLevel > 0) {
		lit = float(ShadowAtlasNearestForVector(shadowMap, shadowRect, L, erodeLevel) >= centerFragZ - errorMargin);
	} else {
		vec4 wgt;
		vec4 centerBlockerZ = ShadowAtlasForVector4(shadowMap, shadowRect, L, wgt);
		lit = dot(wgt, step(centerFragZ - errorMargin, centerBlockerZ));
	}
#else
	float centerBlockerZ = ShadowAtlasForVector(shadowMap, shadowRect, L);
	float lit = float(centerBlockerZ >= centerFragZ - errorMargin);
#endif
	if (softQuality == 0)
		return lit * fallAngleLimiter;

	float lightDist = length(worldFromLight);
	//this is (1 / cos(phi)), where phi is angle between light direction and normal of the pierced cube face
	float secFallAngle = lightDist / maxAbsL;
	//find two unit directions orthogonal to light direction
	vec3 nonCollinear = vec3(1, 0, 0);
	if (absL.x == maxAbsL)
		nonCollinear = vec3(0, 1, 0);
	vec3 orthoAxisX = normalize(cross(L, nonCollinear));
	vec3 orthoAxisY = cross(L, orthoAxisX);

	//search for blockers in a cone with rather large angle
	float searchAngle = 0.03 * softRadius;    //TODO: this option is probably very important
	float minTangentNdl = 0.35 * max(lightFallAngle, 0.05);
	float blockerBias = shadowMapCullFrontHack ? -0.25 * errorMargin : errorMargin;
	float avgBlockerZ = 0.0;
	float blockerWeight = 0.0;
	for (int i = 0; i < softQuality; i++) {
		//use unrotated Poisson disk for blocker search so overlapping occluders do not jitter penumbra radius per pixel
		vec2 sp = u_softShadowsSamples[i];
		vec3 perturbedLightDir = normalize(L + searchAngle * (sp.x * orthoAxisX + sp.y * orthoAxisY));
		float blockerZ = ShadowAtlasNearestForVector(shadowMap, shadowRect, perturbedLightDir, erodeLevel);
		float dotDpL = max(max(abs(perturbedLightDir.x), abs(perturbedLightDir.y)), abs(perturbedLightDir.z));
		float ndl = max(-dot(worldNormal, perturbedLightDir), minTangentNdl);
		float distCoeff = clamp(lightFallAngle / ndl * (dotDpL * secFallAngle), 0.5, 2.0);
		float fragZ = centerFragZ * distCoeff;
		//note: only things which may potentially occlude are averaged; center-weighted for smooth overlap transitions
		if (blockerZ < fragZ - blockerBias) {
			float w = exp(-3.0 * dot(sp, sp));
			avgBlockerZ += blockerZ * w;
			blockerWeight += w;
		}
	}
	//shortcut: no blockers in search angle (and central ray unoccluded) => fully lit
	if (blockerWeight <= 0.0) {
		if (lit >= 0.999)
			return fallAngleLimiter;
		avgBlockerZ = centerFragZ;
	} else {
		avgBlockerZ /= blockerWeight;
	}

	//radius of light source
	float lightRadius = softRadius;
	//radius of one-point penumbra at the considered point (in world coordinates)
	//note that proper formula is:  lightRadius * (lightDist - occlDist) / occlDist;
	float penumbraDepth = max(centerFragZ - avgBlockerZ, 0.0);
	float blurRadiusWorld = lightRadius * penumbraDepth / max(avgBlockerZ, 1e-3);
	//limit blur radius from below to avoid pixelation, without letting coarse distant tiles expand past search cone
	const float minBlurInShadowPixels = 5.0;
	float minBlurRel = min(minBlurInShadowPixels / (shadowMapResolution * secFallAngle), max(searchAngle, 0.012));
	//blur radius relative to light distance, clamped to [minBlurRel, max(searchAngle, minBlurRel)]
	float blurRadiusRel = clamp(blurRadiusWorld / max(lightDist, 1.0), minBlurRel, max(searchAngle, minBlurRel));

	mat2 patternRot = softShadowsPatternRotation();
	float weightSum = 1.0;
	for (int i = 0; i < softQuality; i++) {
		//unit vector L' = perturbed version of L
		vec2 sp = patternRot * u_softShadowsSamples[i];
		float sampleWeight = softShadowsSampleWeight(u_softShadowsSamples[i]);
		vec3 perturbedLightDir = normalize(L + blurRadiusRel * (sp.x * orthoAxisX + sp.y * orthoAxisY));
		//exactly raytrace tangent plane of the surface
		//the multiplier is:  (cos(D ^ L') / cos(N ^ L')) / (cos(D ^ L) / cos(N ^ L))
		//where L and L' is central/perturbed light direction, D is normal of active cubemap face, and N is normal of tangent plane
		float dotDpL = max(max(abs(perturbedLightDir.x), abs(perturbedLightDir.y)), abs(perturbedLightDir.z));
		float ndl = max(-dot(worldNormal, perturbedLightDir), minTangentNdl);
		float distCoeff = clamp(lightFallAngle / ndl * (dotDpL * secFallAngle), 0.5, 2.0);
		float fragZ = centerFragZ * distCoeff;
#if STGATILOV_USEGATHER && defined(GL_ARB_texture_gather)
		if (erodeLevel > 0) {
			float blockerZ = ShadowAtlasNearestForVector(shadowMap, shadowRect, perturbedLightDir, erodeLevel);
			lit += sampleWeight * float(blockerZ >= fragZ - errorMargin);
		} else {
			vec4 wgt;
			vec4 blockerZ4 = ShadowAtlasForVector4(shadowMap, shadowRect, perturbedLightDir, wgt);
			lit += sampleWeight * dot(wgt, step(fragZ - errorMargin, blockerZ4));
		}
#else
		float blockerZ = ShadowAtlasNearestForVector(shadowMap, shadowRect, perturbedLightDir, erodeLevel);
		lit += sampleWeight * float(blockerZ >= fragZ - errorMargin);
#endif
		weightSum += sampleWeight;
	}
	lit /= weightSum;

	return lit * fallAngleLimiter;
}


// Debug helper: describes the decision of the central shadow map sample (no soft shadows, no erode).
// x: 0 = shadowed, 1 = lit, 2 = lit because the shadow map texel is empty (nothing was rendered there), 3 = lit, but within the error margin band (ambiguous)
// y: absolute value of error margin, in shadow map texels
vec2 debugShadowMapCenter(
	vec3 worldFromLight, vec3 worldNormal,
	sampler2D shadowMap, vec4 shadowRect, bool shadowMapCullFrontHack
) {
	float shadowMapResolution = (textureSize(shadowMap, 0).x * shadowRect.w);
	vec3 L = normalize(worldFromLight);
	vec3 absL = abs(worldFromLight);
	float maxAbsL = max(absL.x, max(absL.y, absL.z));
	float lightFallAngle = -dot(worldNormal, L);
	float errorMargin = 5.0 * maxAbsL / ( shadowMapResolution * max(lightFallAngle, 0.1) );
	if (shadowMapCullFrontHack)
		errorMargin *= -.5;
	float fragZ = maxAbsL;
	float blockerZ = ShadowAtlasForVector(shadowMap, shadowRect, L);
	float marginTexels = abs(errorMargin) * shadowMapResolution / maxAbsL;
	float state;
	if (blockerZ < fragZ - errorMargin)
		state = 0.0;
	else if (blockerZ > 1e6)
		state = 2.0;
	else if (abs(blockerZ - (fragZ - errorMargin)) < 0.5 * abs(errorMargin))
		state = 3.0;
	else
		state = 1.0;
	return vec2(state, marginTexels);
}