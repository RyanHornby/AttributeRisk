
#' AttributeRisk
#' 
#' Calculates the attribute disclosure risk for sequentially synthesized datasets.
#' Categorical variables are identified either by factors or by the categorical arg.
#' If strange/unexpected behavior is seen with factors, try identifying categorical
#' variables with the additional argument and remove factors from the dataset.
#' 
#' @param modelFormulas A list of synthesis formulas, or formula like objects (\code{\link[brms]{bf}} for example), in order of synthesis.
#' @param origdata A dataframe of the confidential dataset.
#' @param syndata A list of the synthetic dataset(s).
#' @param posteriorMCMCs A list, in order of synthesis, of the MCMC parameter draws.
#' @param syntype A vector, in order of synthesis, of strings describing the synthesis model. Currently supported models are: norm, binom, multinom, and pois.
#' @param G A vector, in order of synthesis, or a scalar describing the number of guesses (including the confidential value) to evaluate. In the case of a scalar G, that value will be applied to all continuous variables.
#' @param H A scalar determining the amount of iterations. Higher values provide a more accurate estimate but will take longer to compute.
#' @param percentBounds A two element vector determining the lowest and highest guesses. By default the lowest and highest guesses will be 10\% below and 10\% above the confidential value respectively.
#' @param additiveBounds A two element vector determining the lowest and highest guesses. The lowest guess will be the confidential value minus the first value while the highest will be the confidential value plus the second value.
#' @param bounds A two element vector determining the lowest and highest guesses. These guess values are set to be the values from this vector.
#' @param guesses A list, in order of synthesis, containing vectors of guesses for each synthesized variable.
#' @param simplePrior A scalar determining how much more (or less) likely the confidential value is believed to be guessed.
#' @param categorical A vector, in order of synthesis, of booleans denoting if the synthesized variable is to be treated as categorical (guesses set to all values seen in the dataset).
#' 
#' @return a list of lists (one for each record), where each inner list contains the following:
#' \itemize{
#' \item The full probability matrix.
#' \item The marginal probabilities.
#' \item The true value probability.
#' \item The ranking of the guess with the highest probability.
#' \item The ranking of the true value.
#' \item The marginal absolute difference between the guesses with the highest probability and the true values.
#' }
#' 
#' @import progress
#' @export
AttributeRisk = function(modelFormulas, origdata, syndata, posteriorMCMCs, syntype, H = 50,
                         G = 11, percentBounds = c(0.1, 0.1), additiveBounds = NULL, 
                         bounds = NULL, guesses = NULL, simplePrior = NULL, categorical = NULL) {
  
  rtn = list()
  pb <- progress_bar$new(format = "[:bar] :percent eta: :eta", total = length(origdata[, 1]))
  pb$tick(0)
  
  for (i in 1:length(origdata[, 1])) {
    temp = AttributeRiskForRecordI(modelFormulas, i, origdata, syndata, 
                                              posteriorMCMCs, syntype, H, G,
                                              percentBounds, additiveBounds, bounds,
                                              guesses, simplePrior, categorical)

    rtn[[i]] = list(FullProb = temp[[1]], TrueMarginals = temp[[2]], TrueValProb = temp[[3]],
                    RankHighest = temp[[4]][1, ], RankTrue = temp[[4]][which(temp[[4]][, 2] == temp[[3]])],
                    MarginalAbsDiffs = temp[[5]])
    
    pb$tick()
  }
  
  return(rtn)
}

#' AttributeRiskForRecordI
#' 
#' Calculates the attribute disclosure risk for single records in sequentially 
#' synthesized datasets. Categorical variables are identified either by factors 
#' or by the categorical arg. If strange/unexpected behavior is seen with factors,
#' try identifying categorical variables with the additional argument and remove 
#' factors from the dataset.
#' 
#' @param modelFormulas A list of synthesis formulas, or formula like objects (\code{\link[brms]{bf}} for example), in order of synthesis.
#' @param i The record to estimate the risk for.
#' @param origdata A dataframe of the confidential dataset.
#' @param syndata A list of the synthetic dataset(s).
#' @param posteriorMCMCs A list, in order of synthesis, of the MCMC parameter draws.
#' @param syntype A vector, in order of synthesis, of strings describing the synthesis model. Currently supported models are: norm, binom, multinom, and pois.
#' @param G A vector, in order of synthesis, or a scalar describing the number of guesses (including the confidential value) to evaluate. In the case of a scalar G, that value will be applied to all continuous variables.
#' @param H A scalar determining the amount of iterations. Higher values provide a more accurate estimate but will take longer to compute.
#' @param percentBounds A two element vector determining the lowest and highest guesses. By default the lowest and highest guesses will be 10\% below and 10\% above the confidential value respectively.
#' @param additiveBounds A two element vector determining the lowest and highest guesses. The lowest guess will be the confidential value minus the first value while the highest will be the confidential value plus the second value.
#' @param bounds A two element vector determining the lowest and highest guesses. These guess values are set to be the values from this vector.
#' @param guesses A list, in order of synthesis, containing vectors of guesses for each synthesized variable.
#' @param simplePrior A scalar determining how much more (or less) likely the confidential value is believed to be guessed.
#' @param categorical A vector, in order of synthesis, of booleans denoting if the synthesized variable is to be treated as categorical (guesses set to all values seen in the dataset).
#' @return a list of lists (one for each record), where each inner list contains the following:
#' \itemize{
#' \item The full probability matrix.
#' \item The marginal probabilities.
#' \item The true value probability.
#' \item The ranking of the probabilities of all the guesses.
#' \item The marginal absolute difference between the guesses with the highest probability and the true values.
#' }
#' @import matrixStats
#' @export
AttributeRiskForRecordI = function(modelFormulas, i, origdata, syndata, 
                                                     posteriorMCMCs, syntype, H = 50, G = 11, 
                                                     percentBounds = c(0.1, 0.1), 
                                                     additiveBounds = NULL, bounds = NULL,
                                                     guesses = NULL, simplePrior = NULL,
                                                     categorical = NULL) {
  X_i_syn = list()
  X_i_org = list()
  y_i = list()
  y_i_guesses = list()
  orig_mean = list()
  D = c()
  true_value_indx = c()
  is_synthesized = c()
  is_factor = c()
  synthesized_predictors = list()
  
  first = TRUE
  
  for (j in 1:length(modelFormulas)) {
    
    if (is.null(categorical)) {
      is_factor[j] = paste(text = modelFormulas[[j]]$formula[[2]]) %in% names(Filter(is.factor, origdata))
    } else {
      is_factor[j] = FALSE
    }
    
    
    
    ff = as.formula(modelFormulas[[j]])
    
    for (m in 1:length(syndata)) {
      if (m == 1) {
        X_i_syn[[j]] = list()
      }
      model <- model.frame(ff, syndata[[m]])
      X_i_syn[[j]][[m]] <- model.matrix(ff, model)
    }
    
    
    model <- model.frame(ff, origdata)
    X_i_org[[j]] <- model.matrix(ff, model)
    
    is_synthesized[j] = paste(text = modelFormulas[[j]]$formula[[2]])
    temp = c()
    
    for (k in 1:length(is_synthesized)) {
      if (is_synthesized[k] %in% paste(text=modelFormulas[[j]]$formula[[3]])) {
        temp = append(temp, is_synthesized[k])
        #print(temp)
      }
    }
    synthesized_predictors[[j]] = temp
    
    if (is_factor[j]) {
      y_i[[j]] = as.numeric(origdata[i, paste(text = modelFormulas[[j]]$formula[[2]])])
    } else {
      y_i[[j]] = origdata[i, paste(text = modelFormulas[[j]]$formula[[2]])]
    }
    
    if (syntype[j] != "multinom") {
      orig_mean[[j]] = t(as.matrix(X_i_org[[j]][i, ])) %*% t(as.matrix(posteriorMCMCs[[j]][, !names(posteriorMCMCs[[j]]) %in% c("sigma")]))
    }
    
    y_i_guesses[[j]] = NULL
    if (is_factor[j]) {
      y_i_guesses[[j]] = as.numeric(levels(origdata[, paste(text = modelFormulas[[j]]$formula[[2]])]))
      D[j] = length(y_i_guesses[[j]])
    } else if (!is.null(categorical) && categorical[j]) {
      y_i_guesses[[j]] = unique(origdata[, paste(text = modelFormulas[[j]]$formula[[2]])])
      D[j] = length(y_i_guesses[[j]])
    } else {
      if (length(G) == 1) {
        D[j] = G
      } else {
        D[j] = G[j]
      }
      
      if (is.null(guesses) == FALSE) {
        y_i_guesses[[j]] = guesses[[j]]
      } else if (is.null(additiveBounds) == FALSE) {
        y_i_guesses[[j]] = seq(y_i[[j]] - additiveBounds[1], y_i[[j]] + additiveBounds[2], length.out = D[j])
      } else if (is.null(bounds) == FALSE) {
        y_i_guesses[[j]] = seq(bounds[1], bounds[2], length.out = D[j])
      } else {
        y_i_guesses[[j]] = seq(y_i[[j]] * (1 - percentBounds[1]), y_i[[j]] * (1 + percentBounds[2]), length.out = D[j])
      }
    }
    
    
    
    if (!(y_i[[j]] %in% y_i_guesses[[j]])) {
      #if (first == TRUE) {
      #  y_i_guesses[[j]] = append(y_i_guesses[[j]], y_i[[j]])
      #  G = G + 1
      #  first = FALSE
      #} else {
      warning("Replaced median value in guess range with true value.")
        y_i_guesses[[j]] = replace(y_i_guesses[[j]], y_i_guesses[[j]] == median(y_i_guesses[[j]]), y_i[[j]])
        
        #}
    }
    
    true_value_indx[j] = match(y_i[[j]], y_i_guesses[[j]])
    #print(y_i[[j]])
    #print(y_i_guesses[[j]])
    
    #print(true_value_indx[j])
  }
  #print(true_value_indx)
  
  unnormalized_prob = rep(0, prod(D))
  
  for (m in 1:length(syndata)) {
    
    CU_i_logZ_all <-rep(NA, prod(D))
    for (j in 1:length(CU_i_logZ_all)) {
      
      currentGuesses = index_to_guesses(j, D, y_i_guesses, is_synthesized)
      #print(j)
      #print(currentGuesses)
      #print("Orig Row:")
      #print(X_i_org[[1]][i, ])
      guessed = guessed_mean(origdata, i, as.formula(modelFormulas[[1]]), currentGuesses, synthesized_predictors, posteriorMCMCs, syntype, 1, -1)
      
      
      #print(y_i[[1]])
      
      q_sum_H = (densityCalc(y_i_guesses[[1]][((j-1) %% D[1])+1], syntype[1], guessed, posteriorMCMCs[[1]][, "sigma"], D[1], posteriorMCMCs[[1]])
                 /densityCalc(y_i[[1]], syntype[1], orig_mean[[1]], posteriorMCMCs[[1]][, "sigma"], D[1], posteriorMCMCs[[1]]))
      
      #print(q_sum_H)
      #t(as.matrix(X_i_org[[j]][i, ])) %*% t(as.matrix(posteriorMCMCs[[j]][, !names(posteriorMCMCs[[j]]) %in% c("sigma")]))
      
      if (length(modelFormulas) > 1) {  
        for (l in 2:length(modelFormulas)) {
          #print("Orig Row:")
          #print(X_i_org[[l]][i, ])
          guessed = guessed_mean(origdata, i, as.formula(modelFormulas[[l]]), currentGuesses, synthesized_predictors, posteriorMCMCs, syntype, l, -1)
          
          q_sum_H = q_sum_H * (densityCalc(y_i_guesses[[l]][get_index(D, j, l)], syntype[l], guessed, posteriorMCMCs[[l]][, "sigma"], D[l], posteriorMCMCs[[l]])
                               /densityCalc(y_i[[l]], syntype[l], orig_mean[[l]], posteriorMCMCs[[l]][, "sigma"], D[l], posteriorMCMCs[[l]]))
          
        }
      }
      
      q_sum_H = sum(q_sum_H)
      log_pq_h_all = rep(NA, H)
      for(h in 1:H) {
        log_p_h = 1
        for (l in 1:length(modelFormulas)) {
          if (is_factor[l]) {
            log_p_h = log_p_h * densityCalc(as.numeric(syndata[[m]][, paste(text = modelFormulas[[l]]$formula[[2]])]) - 1, syntype[l], 
                                            as.matrix(X_i_syn[[l]][[m]]) %*% t(as.matrix(posteriorMCMCs[[l]][h , !names(posteriorMCMCs[[l]]) %in% c("sigma")])),
                                            posteriorMCMCs[[l]][h, "sigma"], D[l], posteriorMCMCs[[l]][h, ])
          } else {
            log_p_h = log_p_h * densityCalc(syndata[[m]][, paste(text = modelFormulas[[l]]$formula[[2]])], syntype[l], 
                                            as.matrix(X_i_syn[[l]][[m]]) %*% t(as.matrix(posteriorMCMCs[[l]][h , !names(posteriorMCMCs[[l]]) %in% c("sigma")])),
                                            posteriorMCMCs[[l]][h, "sigma"], D[l], posteriorMCMCs[[l]][h, ])
          }
        }
        log_p_h = sum(log(log_p_h))
        
        guessed = guessed_mean(origdata, i, as.formula(modelFormulas[[1]]), currentGuesses, synthesized_predictors, posteriorMCMCs, syntype, 1, h)
        
        log_q_h = (densityCalc(y_i_guesses[[1]][((j-1) %% D[1])+1],syntype[1],
                    guessed,
                    posteriorMCMCs[[1]][h, "sigma"], D[1], posteriorMCMCs[[1]][h, ])
                   /densityCalc(y_i[[1]], syntype[1],
                     t(as.matrix(X_i_org[[1]][i, ])) %*% t(as.matrix(posteriorMCMCs[[1]][h, !names(posteriorMCMCs[[1]]) %in% c("sigma")])),
                    posteriorMCMCs[[1]][h, "sigma"], D[1], posteriorMCMCs[[1]][h, ]))
        
        if (length(modelFormulas) > 1) {
          for (l in 2:length(modelFormulas)) {
            guessed = guessed_mean(origdata, i, as.formula(modelFormulas[[l]]), currentGuesses, synthesized_predictors, posteriorMCMCs, syntype, l, h)
  
            log_q_h = log_q_h * (densityCalc(y_i_guesses[[l]][get_index(D, j, l)],syntype[l],
                                  guessed,
                                  posteriorMCMCs[[l]][h, "sigma"], D[l], posteriorMCMCs[[l]][h, ])
                                 /densityCalc(y_i[[l]], syntype[l],
                                  t(as.matrix(X_i_org[[l]][i, ])) %*% t(as.matrix(posteriorMCMCs[[l]][h, !names(posteriorMCMCs[[l]]) %in% c("sigma")])),
                                  posteriorMCMCs[[l]][h, "sigma"], D[l], posteriorMCMCs[[l]][h, ]))
          }
        }
        
        log_q_h = log(log_q_h/q_sum_H)
        
        log_pq_h_all[h] = log_p_h + log_q_h
      }
      
      if (!is.null(simplePrior)) {
        true_value = TRUE
        for (k in 1:length(currentGuesses)) {
          if (currentGuesses[k] != origdata[i, is_synthesized[k]]) {
            true_value = FALSE
            break
          }
        }
        denom = length(CU_i_logZ_all) + simplePrior - 1
        if (true_value) {
          CU_i_logZ_all[j] = logSumExp(log_pq_h_all) + (simplePrior / denom)
        } else {
          CU_i_logZ_all[j] = logSumExp(log_pq_h_all) + (1 / denom)
        }
      } else {
        CU_i_logZ_all[j] = logSumExp(log_pq_h_all)
      }
    }
  
    unnormalized_prob = unnormalized_prob + CU_i_logZ_all
    
  }
  
  prob <-exp(unnormalized_prob- max(unnormalized_prob))/sum(exp(unnormalized_prob- max(unnormalized_prob)))
  #outcome = array(prob, dim = rep(G, length(modelFormulas)), dimnames = y_i_guesses)
  outcome = array(prob, dim = sapply(y_i_guesses, length), dimnames = y_i_guesses)
  
  marginals = c()
  true_val_string = "outcome["
  if (length(modelFormulas) > 1) {
    for (j in 1:(length(modelFormulas)-1)) {
      true_val_string = paste(true_val_string, true_value_indx[j], ",", sep = "")
      marginals[j] = sum(eval(parse(text=paste("outcome[", strrep(",", j - 1), true_value_indx[j], strrep(",", length(modelFormulas) - j), "]", sep = ""))))
    }
  }
  true_val_string = paste(true_val_string, true_value_indx[length(modelFormulas)], "]", sep = "")
  marginals[length(modelFormulas)] = sum(eval(parse(text=paste("outcome[", paste(strrep(",", length(modelFormulas) - 1), true_value_indx[length(modelFormulas)], "]", sep = "")))))
  
  diffs = get_abs_diff(outcome, origdata, y_i, y_i_guesses, D)
  
  return(list(FullProb = outcome, TrueMarginals = marginals, TrueValProb = eval(parse(text = true_val_string)), Ranks = get_ranks(outcome, is_synthesized), AbsDiff = diffs))
  
}

#' randomGuessPlot
#' 
#' Produces a graph of the probabilities of each guess with a line indicating 
#' the chance of randomly guessing the confidential value(s) from among the 
#' guesses.
#' 
#' @param risks List containing the true value probabilities (output from \code{\link[AttributeRiskCalculation]{AttributeRisk}})
#' @param custom_palette Vector of color values to use for the plot. Will use the first value for the density and the last for the vertical line.
#' @return A ggplot plot object containing the desired plot.
#'
#' @import ggplot2
#' @export
randomGuessPlot = function(risks, custom_palette = NULL) {
  true_risks = c()
  for (i in 1:length(risks)) {
    true_risks[i] = risks[[i]]$TrueValProb
  }
  plotdf = as.data.frame(true_risks)
  plt = ggplot(data = plotdf) + geom_density(aes(abs(true_risks), color = "density"), size = 1) + 
    theme(panel.background = element_rect(fill = "white", color = "black"),
          panel.grid.major = element_line(color = "grey")) + 
    labs(x = "Probability of guessing correctly", y = "Density")
  
  if (!is.null(custom_palette)) {
    plt = plt + geom_vline(aes(xintercept = 1.0/length(risks[[1]]$FullProb)), col = custom_palette[length(custom_palette)], size = 1) +
                scale_color_manual(values = custom_palette)
  } else {
    plt = plt + geom_vline(aes(xintercept = 1.0/length(risks[[1]]$FullProb)), col = "red", size = 1)
  }
  
  plt
  return(plt)
}

densityCalc = function (x, type, otherArg1, otherArg2, otherArg3, otherArg4) {
  if (type == "norm") {
    return(dnorm(x, otherArg1, otherArg2))
  } else if (type == "binom") {
    y = dbinom(x, 1, logistic(otherArg1))
    return(y)
  } else if (type == "multinom") {
    if (is.null(nrow(otherArg4))) {
      return(otherArg4[x])
    } else {
      return(otherArg4[, x])
    }
  } else if (type == "pois") {
    return(dpois(x, exp(otherArg1)))
  } else {
    stop(paste("Unknown variable type", type))
  }
}

logistic = function (x) {
  return(1/(1+exp(-x)))
}

get_index = function(D, j, l) {
  cnt = 1
  if (l > 1) {
    for (i in 1:(l-1)) {
      cnt = cnt * D[i]
    }
  }
  rtn = as.integer((j - 1) / cnt) + 1
  return(rtn)
}

index_to_guesses = function(j, D, guesses, guess_names) {
  rtn = c()
  for (i in 1:length(D)) {
    if (i == 1) {
      rtn[i] = guesses[[i]][((j-1) %% D[i]) + 1] 
    } else {
      rtn[i] = guesses[[i]][as.integer((j-1) / D[i]) + 1]
    }
  }
  names(rtn) = guess_names
  return(rtn)
}

guessed_mean = function(origdata, i, model_formula, currentGuesses, synthesized_predictors, posteriorMCMCs, syntype, l, h) {
  if (syntype[l] == "multinom") {return(NULL)}
  
  temp = origdata[i, ]
  if (length(synthesized_predictors) > 1) {
    for (j in 1:length(synthesized_predictors[[l]])) {
      temp = replace(temp, synthesized_predictors[[l]][j], currentGuesses[synthesized_predictors[[l]][j]])
    }
  }
  model <- model.frame(model_formula, temp)
  temp <- model.matrix(model_formula, model)
  #print(temp)
  if (h == -1) {
    #print(dim(t(as.matrix(temp))))
    #print(dim(t(as.matrix(posteriorMCMCs[[l]][, !names(posteriorMCMCs[[l]]) %in% c("sigma")]))))
    guessed = as.matrix(temp) %*% t(as.matrix(posteriorMCMCs[[l]][, !names(posteriorMCMCs[[l]]) %in% c("sigma")]))
  } else {
    guessed = as.matrix(temp) %*% t(as.matrix(posteriorMCMCs[[l]][h, !names(posteriorMCMCs[[l]]) %in% c("sigma")]))
  }
  return(guessed)
}

#'
#'
#' @import arrayhelpers
get_ranks = function(full_prob, guessed_names) {
  rtn = array2df(full_prob, matrix = TRUE)
  rtn = rtn[order(rtn[,1], decreasing = TRUE), ]
  
  for (i in 1:length(guessed_names)) {
    vals = as.numeric(dimnames(full_prob)[[i]])
    for (j in 1:length(dimnames(full_prob)[[i]])) {
      rtn[rtn[, i + 1] == j, i + 1] = vals[j]
    }
  }
  
  rtn = cbind(1:(length(rtn[,1])), rtn)
  colnames(rtn) = c("rank", "prob", guessed_names)
  return(rtn)
}

get_abs_diff = function(output, origdata, y_i, y_i_guesses, D) {
  rtn = c()
  N = length(y_i)
  for (i in 1:N) {
    indx = 0
    max_marg = 0
    for (j in 1:D[i]) {
      temp = sum(eval(parse(text=paste("output[", strrep(",", i-1), j, strrep(",", N-i), "]", sep = ""))))
      if (temp > max_marg) {
        max_marg = temp
        indx = j
      }
    }
    
    rtn[i] = y_i[[i]] - y_i_guesses[[i]][indx]  
    
    if (i < N) {
      #rtn[i] = y_i[[i]] - eval(parse(text=paste("names(output[", strrep("1,", i-1), ",", strrep("1,", N-i-1), "1])[", indx, "]", sep="")))
    } else {
      #rtn[i] = y_i[[i]] - eval(parse(text=paste("names(output[", strrep("1,", i-1), "])[", indx, "]", sep="")))
    }
  }
  return(abs(rtn))
}
