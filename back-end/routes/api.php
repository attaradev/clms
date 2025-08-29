<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\Api\AuthenticationController;
use App\Http\Controllers\Api\PasswordResetController;
use App\Http\Controllers\Api\UserController;

Route::get('health', function () {
    return response()->json(['status' => 'ok']);
});

// Auth (public)
Route::post('login',  [AuthenticationController::class, 'login']);
Route::post('password/forgot', [PasswordResetController::class, 'forgotPassword']);
Route::post('password/reset',  [PasswordResetController::class, 'resetPassword']);

// Auth-required
Route::middleware('auth:sanctum')->group(function () {
    Route::post('logout', [AuthenticationController::class, 'logout']);

    Route::patch('users/{user}/change-password', [AuthenticationController::class, 'changePassword']);
    Route::patch('users/{user}',                 [UserController::class, 'update']);

    Route::prefix('admin')->group(function () {
        Route::apiResource('users', UserController::class);
    });
});
